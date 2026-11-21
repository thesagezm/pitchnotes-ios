import XCTest
@testable import EngineCore

// SwiftF0 portable-core tests (P-101). The real model is validated by the
// Python spike (Tests/Spikes, macOS CI); these tests pin the portable math
// (gate/loudness parity vs the pinned model's outputs), the windowing/stream
// state machines, the band filter, the resampler, and the WAV reader.

final class SwiftF0CoreTests: XCTestCase {

    // MARK: - Parity vs pinned-model reference vectors

    func testGateAndLoudnessParityWithReferenceVectors() {
        let audio = SwiftF0ReferenceVectors.Audio.values // 2048 samples, 8 frames
        XCTAssertEqual(audio.count, SwiftF0Spec.hop * 8)
        // Gate is a passthrough on this audio (peaks ≫ silence floor): any raw
        // confidence must come out unchanged (the reference CONF values are the
        // pinned model's own outputs — they exercise loudness parity below).
        let rawConf: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
        let gated = SwiftF0Postprocessor.gateConfidence(audio: audio, frameCount: 8, confidence: rawConf)
        XCTAssertEqual(gated, rawConf, "gate must not alter confidence on audible audio")
        let loudness = SwiftF0Postprocessor.loudness(audio: audio, frameCount: 8)
        XCTAssertEqual(loudness.count, SwiftF0ReferenceVectors.Loudness.values.count)
        for (a, b) in zip(loudness, SwiftF0ReferenceVectors.Loudness.values) {
            XCTAssertEqual(a, b, accuracy: 1e-7, "loudness parity")
        }
    }

    func testLoudnessKnownSine() {
        // 0.5-amp 220 Hz sine: same signal as the reference vectors, so frame
        // values must match the pinned model's postprocessing EXACTLY (the
        // ideal rms = 0.5/√2 ⇒ −9.03 dB has partial-period ripple: 256 samples
        // @16k = 3.52 periods of 220 Hz, which is why the exact value is
        // −9.055 dB — the pinned-model probe confirms the same median −9.03).
        let n = 512
        let sine = (0..<n).map { Float(0.5 * sin(2.0 * .pi * 220.0 * Double($0) / 16000.0)) }
        let loudness = SwiftF0Postprocessor.loudness(audio: sine, frameCount: 2)
        XCTAssertEqual(loudness[1], SwiftF0ReferenceVectors.Loudness.values[1], accuracy: 1e-9)
        XCTAssertTrue(loudness[0] > -20 && loudness[0] < -6, "frame0 \(loudness[0])")
        // Analytic bound: |value − ideal| must stay small (partial-period ripple).
        XCTAssertEqual(loudness[1], 20.0 * log10(0.5 / sqrt(2.0)), accuracy: 0.05)
    }

    func testSilenceGate() {
        let silence = [Float](repeating: 0, count: 256)
        var conf: [Float] = [0.97]
        conf = SwiftF0Postprocessor.gateConfidence(audio: silence, frameCount: 1, confidence: conf)
        XCTAssertEqual(conf[0], 0.0, "digital silence must gate to confidence 0")

        let subFloor = [Float](repeating: 1e-4, count: 256)
        conf = [0.9]
        conf = SwiftF0Postprocessor.gateConfidence(audio: subFloor, frameCount: 1, confidence: conf)
        XCTAssertEqual(conf[0], 0.0, "peak below 1e-3 must gate")

        let aboveFloor = (0..<256).map { _ in Float.random(in: 0.02...0.05) }
        conf = [0.9]
        conf = SwiftF0Postprocessor.gateConfidence(audio: aboveFloor, frameCount: 1, confidence: conf)
        XCTAssertEqual(conf[0], 0.9, "peak above 1e-3 must NOT gate")
    }

    // MARK: - Band filter

    func testBandClampsToModelRange() throws {
        let band = try SwiftF0Band(fmin: 30.0, fmax: 9999.0)
        XCTAssertEqual(band.fmin, SwiftF0Spec.fmin, accuracy: 1e-9)
        XCTAssertEqual(band.fmax, SwiftF0Spec.fmax, accuracy: 1e-9)
        let narrow = try SwiftF0Band(fmin: nil, fmax: nil) // defaults
        XCTAssertEqual(narrow.fmin, SwiftF0Spec.fmin, accuracy: 1e-9)
    }

    func testBandRejectsInvalidRanges() {
        XCTAssertThrowsError(try SwiftF0Band(fmin: 300.0, fmax: 200.0))
        XCTAssertThrowsError(try SwiftF0Band(fmin: 1000.0, fmax: 1001.0), "band narrower than one bin must throw")
        do {
            _ = try SwiftF0Band(fmin: 300.0, fmax: 200.0)
            XCTFail("expected contractViolation")
        } catch let error as EngineError {
            if case .contractViolation(let msg) = error {
                XCTAssertTrue(msg.contains("fmin < fmax"), msg)
            } else {
                XCTFail("wrong error kind: \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - Batch windowing

    /// Mock that reports the exact audio slice it received per call and emits
    /// one frame per 256 samples (like the real model).
    final class RecordingInference: SwiftF0Inference, @unchecked Sendable {
        private(set) var received: [[Float]] = []
        private(set) var fmins: [Float] = []
        func run(audio: [Float], fmin: Float, fmax: Float) throws -> (pitch: [Double], confidence: [Float]) {
            received.append(audio)
            fmins.append(fmin)
            let frames = max(1, audio.count / SwiftF0Spec.hop)
            let pitch = (0..<frames).map { Double($0 + 100) }
            return (pitch, [Float](repeating: 0.8, count: frames))
        }
    }

    func testBatchWindowSlicingMatchesUpstream() throws {
        let recorder = RecordingInference()
        let frames = 4000 // > windowFrames ⇒ 3 windows
        let audio = [Float](repeating: 0.1, count: frames * SwiftF0Spec.hop)
        let engine = SwiftF0PitchEngine(inference: recorder)
        _ = try engine.detect(samples: audio, sampleRate: 16_000)

        let calls = recorder.received
        XCTAssertEqual(calls.count, 3, "4000 frames / 1875-window ⇒ 3 windows")
        // Window 1: frames [0, 1875+10) → 1885·256 samples (EOF window extends).
        XCTAssertEqual(calls[0].count, (SwiftF0Spec.windowFrames + SwiftF0Spec.lookaheadFrames) * SwiftF0Spec.hop)
        // Window 2: start=1875, left=1864, end=3750, right=+10 → 3760−1864=1896 frames.
        XCTAssertEqual(calls[1].count, (3760 - 1864) * SwiftF0Spec.hop)
        // Final window: EOF → no lookahead extension: start=3750, left=3739 → 261 frames.
        XCTAssertEqual(calls[2].count, (frames - 3739) * SwiftF0Spec.hop)
        // fmin/fmax forwarded verbatim.
        XCTAssertEqual(recorder.fmins, [Float](repeating: Float(SwiftF0Spec.fmin), count: 3))
    }

    func testBatchContractFramesGridAndUnvoicedMapping() throws {
        struct ConstantInference: SwiftF0Inference {
            let conf: Float
            func run(audio: [Float], fmin: Float, fmax: Float) throws -> (pitch: [Double], confidence: [Float]) {
                let frames = max(1, audio.count / SwiftF0Spec.hop)
                return ((0..<frames).map { _ in 220.0 }, [Float](repeating: conf, count: frames))
            }
        }
        let audio = [Float](repeating: 0.5, count: 10 * SwiftF0Spec.hop)
        // Voiced: confidence 0.9 ≥ 0.5 → hz passthrough.
        let voiced = try SwiftF0PitchEngine(inference: ConstantInference(conf: 0.9))
            .detectContractFrames(samples: audio, sampleRate: 16_000)
        XCTAssertEqual(voiced.count, 10)
        for (i, f) in voiced.enumerated() {
            XCTAssertEqual(f.t, Double(i) * 0.016, accuracy: 1e-12, "C-2.4 uniform grid")
            XCTAssertEqual(f.hz, 220.0, accuracy: 1e-9)
        }
        // Unvoiced: confidence 0.49 < 0.5 → hz MUST be 0 (V11 semantics).
        let unvoiced = try SwiftF0PitchEngine(inference: ConstantInference(conf: 0.49))
            .detectContractFrames(samples: audio, sampleRate: 16_000)
        for f in unvoiced {
            XCTAssertEqual(f.hz, 0.0, "sub-threshold confidence maps to unvoiced")
            XCTAssertEqual(f.confidence, 0.49, accuracy: 1e-6)
        }
    }

    // MARK: - Streaming state machine

    func testStreamEmitsOnlyFinalFrames() throws {
        struct ConstantInference: SwiftF0Inference {
            func run(audio: [Float], fmin: Float, fmax: Float) throws -> (pitch: [Double], confidence: [Float]) {
                let frames = max(1, audio.count / SwiftF0Spec.hop)
                return ((0..<frames).map { _ in 110.0 }, [Float](repeating: 0.9, count: frames))
            }
        }
        let stream = try SwiftF0PitchEngine(inference: ConstantInference()).stream()
        var all: [SwiftF0Frame] = []
        // Push 1 s in 40 ms chunks (640 samples): after k chunks, k·40/16 = 2.5k
        // frames exist; final = those with 10-lookahead satisfied.
        for _ in 0..<25 {
            let chunk = [Float](repeating: 0.5, count: 640)
            all += try stream.push(chunk)
        }
        let framesIn = 25 * 640 / 256 // 62.5 → 62 full frames
        XCTAssertEqual(all.count, framesIn - SwiftF0Spec.lookaheadFrames, "only frames with 10-frame lookahead emit")
        XCTAssertEqual(stream.emitted, all.count)
        let flushed = try stream.flush()
        XCTAssertEqual(all.count + flushed.count, framesIn, "flush drains the remainder")
        XCTAssertTrue(stream.isClosed)
        XCTAssertThrowsError(try stream.push([Float](repeating: 0, count: 256)), "push after flush throws")
        // Timestamps: strictly increasing on the uniform 16 ms grid (C-2.4/V13).
        let frames = all + flushed
        for (i, f) in frames.enumerated() {
            XCTAssertEqual(f.t, Double(i) * SwiftF0Spec.framePeriod, accuracy: 1e-12)
        }
    }

    func testSubHopFlushYieldsOneFrame() throws {
        struct OneFrameInference: SwiftF0Inference {
            func run(audio: [Float], fmin: Float, fmax: Float) throws -> (pitch: [Double], confidence: [Float]) {
                (pitch: [160.0], confidence: [0.99])
            }
        }
        let stream = try SwiftF0PitchEngine(inference: OneFrameInference()).stream()
        let frames = try stream.push([Float](repeating: 0.5, count: 160)) // 10 ms chunk, sub-hop
        XCTAssertTrue(frames.isEmpty)
        let flushed = try stream.flush()
        XCTAssertEqual(flushed.count, 1, "stream shorter than one hop yields one frame at flush")
        XCTAssertEqual(flushed[0].hz, 160.0, accuracy: 1e-9)
    }

    /// Property (upstream guarantee): for an inference whose receptive field is
    /// ≤ leftFrames/lookaheadFrames, streaming output == batch output exactly.
    func testStreamMatchesBatchForShortReceptiveField() throws {
        // Receptive field: frame value = mean of THIS and the PREVIOUS hop's
        // peaks (2-frame reach ≪ 11/10) ⇒ windowing must not change results.
        struct MeanInference: SwiftF0Inference {
            func run(audio: [Float], fmin: Float, fmax: Float) throws -> (pitch: [Double], confidence: [Float]) {
                let frames = max(1, audio.count / SwiftF0Spec.hop)
                var pitch = [Double](repeating: 0, count: frames)
                for i in 0..<frames {
                    let start = i * SwiftF0Spec.hop
                    let end = min(start + SwiftF0Spec.hop, audio.count)
                    guard start < end else { continue }
                    var s: Double = 0
                    for k in start..<end { s += Double(audio[audio.startIndex + k]) }
                    pitch[i] = 100.0 + s / Double(end - start)
                }
                return (pitch, [Float](repeating: 0.9, count: frames))
            }
        }
        let audio = (0..<3000).map { Float(sin(Double($0) * 0.01) * 0.4) }
        let batch = try SwiftF0PitchEngine(inference: MeanInference()).detect(samples: audio, sampleRate: 16_000)
        let stream = try SwiftF0PitchEngine(inference: MeanInference()).stream()
        var streamed: [SwiftF0Frame] = []
        var i = 0
        while i < audio.count {
            let n = min(1024, audio.count - i)
            streamed += try stream.push(Array(audio[i..<i + n]))
            i += n
        }
        streamed += try stream.flush()
        XCTAssertEqual(streamed.count, batch.count, "stream must emit every frame exactly once")
        for (a, b) in zip(streamed, batch) {
            XCTAssertEqual(a.hz, b.hz, accuracy: 1e-9)
            XCTAssertEqual(a.confidence, b.confidence, accuracy: 1e-9)
            XCTAssertEqual(a.loudness_db, b.loudness_db, accuracy: 1e-9)
        }
    }

    // MARK: - Resampler

    /// Goertzel magnitude at a target frequency (frequency-accuracy probe).
    private func goertzel(_ x: [Float], sampleRate: Double, freq: Double) -> Double {
        let n = Double(x.count)
        let k = (n * freq / sampleRate).rounded()
        let w = 2.0 * .pi * k / n
        let coeff = 2.0 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for v in x {
            let s = Double(v) + coeff * s1 - s2
            s2 = s1
            s1 = s
        }
        return sqrt(s1 * s1 + s2 * s2 - coeff * s1 * s2) / (n / 2.0)
    }

    func testResamplerPreservesFrequencyAndAmplitude() {
        let sr = 44_100
        let dur = 1.5
        let n = Int(Double(sr) * dur)
        let sine = (0..<n).map { Float(0.5 * sin(2.0 * .pi * 1000.0 * Double($0) / Double(sr))) }
        let out = AudioResampler.resampleTo16k(samples: sine, sourceRate: sr)
        XCTAssertEqual(out.count, Int(Double(n) * 16000.0 / Double(sr)), accuracy: 2)
        // Skip resampler edge frames; compare center Goertzel magnitude + freq.
        let center = Array(out[2000..<(out.count - 2000)])
        let mag1k = goertzel(center, sampleRate: 16000, freq: 1000)
        let mag1p2k = goertzel(center, sampleRate: 16000, freq: 1200)
        XCTAssertEqual(mag1k, 0.5, accuracy: 0.05, "amplitude preserved (got \(mag1k))")
        XCTAssertGreaterThan(mag1k / max(mag1p2k, 1e-9), 20.0, "energy stays at 1 kHz")
        // Frequency via zero crossings (center section) within ±5 cents.
        var crossings = 0
        for i in 1..<center.count where center[i - 1] < 0 && center[i] >= 0 { crossings += 1 }
        let measured = Double(crossings) / (Double(center.count) / 16000.0)
        let cents = 1200.0 * log2(measured / 1000.0)
        XCTAssertEqual(cents, 0.0, accuracy: 5.0, "measured \(measured) Hz (\(cents) c)")
    }

    func testResamplerHandlesIdentityAndEmpty() {
        let x = [Float](repeating: 0.3, count: 512)
        XCTAssertEqual(AudioResampler.resample(samples: x, sourceRate: 16000, targetRate: 16000), x)
        XCTAssertTrue(AudioResampler.resample(samples: [], sourceRate: 44100, targetRate: 16000).isEmpty)
    }

    // MARK: - WAV reader (fixtures)

    func testWavReaderReadsCommittedFixture() throws {
        // Locate Tests/Spikes/Fixtures relative to this test file (works on
        // Linux + macOS CI; fixtures are committed per P-001).
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // EngineCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Engine
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Tests/Spikes/Fixtures/silence_16k.wav")
        let content = try PCMWaveReader.read(url: fixture)
        XCTAssertEqual(content.sampleRate, 16000)
        XCTAssertEqual(content.channels, 1)
        XCTAssertEqual(content.samples.count, 32_000, "2 s of silence")
        for v in content.samples where v != 0 { XCTFail("silence fixture must be all zeros"); break }
    }

    func testWavReaderRejectsGarbage() {
        XCTAssertThrowsError(try PCMWaveReader.read(data: Data([0x00, 0x01, 0x02])))
    }
}

