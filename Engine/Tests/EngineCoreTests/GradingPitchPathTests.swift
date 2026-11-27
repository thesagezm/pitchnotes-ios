import XCTest
@testable import EngineCore

// P-401 · The grading-pitch-path tests.
//
// WHAT IS PINNED HERE:
//   (1) THE BATCH IS THE BUNDLE TIMELINE: the grid integrity rule (a frame
//       off the C-2.4 grid is a contract violation, never silently kept), the
//       t=0 == audio t=0 construction, and byte-equal determinism.
//   (2) THE GRADER'S COMPARISON consumes J-403's offset EXACTLY as C-20 §4
//       pins the sign (≥ 0 = live is LATE → compare against t − offset), and
//       the same numbers come out of `PlaybackTransform.referenceTime` — the
//       two surfaces agree because they are one semantic (D-33).
//   (3) THE ESTIMATOR SPLIT: the batch (SwiftF0, post-hoc) vs the causal
//       ribbon (RibbonEngine, D-7) is MEASURED on the same synthetic audio:
//       the onset-time bias between the two estimators is STABLE (it does
//       not drift with the onset's position) and its size is the ribbon's
//       window-end semantics — measured, pinned, and never silently
//       compensated (J-403's loopback calibration owns the live path's real
//       end-to-end latency).
//
// THE INFERENCE MOCK voices exactly when the hop's peak exceeds the silence
// gate — the same decision the real model's silence postprocessor makes — so
// the mock's ONSET is honest for alignment purposes (timing, not pitch
// accuracy, is what these tests measure; the model's accuracy numbers live in
// BENCHMARKS §3, runner-labelled).

final class GradingPitchPathTests: XCTestCase {

    private let sampleRate = 44_100

    /// A mono 44.1 kHz buffer: `duration_s` of silence, then a 220 Hz tone.
    private func audio(silence_s: Double, tone_s: Double) -> [Float] {
        let silenceFrames = Int(silence_s * Double(sampleRate))
        let toneFrames = Int(tone_s * Double(sampleRate))
        var samples = [Float](repeating: 0, count: silenceFrames + toneFrames)
        let twoPiF: Double = 2.0 * Double.pi * 220.0
        for index in silenceFrames..<samples.count {
            let phase = twoPiF * Double(index) / Double(sampleRate)
            samples[index] = Float(0.5 * sin(phase))
        }
        return samples
    }

    /// The inference mock: voice iff the frame's hop peak > the silence gate
    /// (the model's silence postprocessor's own rule), pitch 220 Hz.
    struct GateInference: SwiftF0Inference {
        func run(audio: [Float], fmin: Float, fmax: Float) throws -> (pitch: [Double], confidence: [Float]) {
            let frameCount = audio.count / SwiftF0Spec.hop
            var pitch = [Double](repeating: 0, count: frameCount)
            var confidence = [Float](repeating: 0, count: frameCount)
            for frame in 0..<frameCount {
                let start = frame * SwiftF0Spec.hop
                let length = min(SwiftF0Spec.hop, max(0, audio.count - start))
                var peak: Float = 0
                if length > 0 {
                    for k in 0..<length {
                        let v = abs(audio[start + k])
                        if v > peak { peak = v }
                    }
                }
                if peak >= SwiftF0Spec.silencePeak {
                    pitch[frame] = 220.0
                    confidence[frame] = 0.9
                }
            }
            return (pitch, confidence)
        }
    }

    private func buildBatch(_ samples: [Float]) throws -> GradingPitchBatch {
        try GradingPitchBatch.build(samples: samples, sampleRate: sampleRate,
                                    source: .mix(URL(fileURLWithPath: "/bundle/mix.wav")),
                                    inference: GateInference())
    }

    // MARK: - (1) The batch IS the bundle timeline

    func testTheBatchIsOnTheContractGridAndDeterministic() throws {
        let samples = audio(silence_s: 1.0, tone_s: 1.0)
        let batch = try buildBatch(samples)

        XCTAssertEqual(batch.frames.count, 125, "16 ms grid over 2 s at 16 kHz")
        for (index, frame) in batch.frames.enumerated() {
            XCTAssertEqual(frame.t, Double(index) * 0.016, accuracy: 1e-9,
                           "frames[i].t == i × 0.016 (C-2.4)")
        }
        // The t=0 IS the audio's t=0: the first frames (silence) are unvoiced.
        XCTAssertEqual(batch.frames.first?.hz, 0.0, "the silent lead-in is unvoiced")
        // Duration is the bundle clock's value (44 100 · 2 / 44 100 = 2.0).
        XCTAssertEqual(batch.duration_s, 2.0, accuracy: 1e-9)

        // Determinism: the same samples → a byte-equal batch (the S-rules).
        let second = try buildBatch(samples)
        XCTAssertEqual(second, batch)
    }

    func testAFrameOffTheGridIsAContractViolation() throws {
        var frames = (0..<10).map { index in
            PitchFrame(t: Double(index) * 0.016, hz: index == 5 ? 220 : 0,
                       confidence: index == 5 ? 0.9 : 0, loudness_db: -60)
        }
        frames[7].t += 0.001 // one millisecond off the grid
        XCTAssertThrowsError(try GradingPitchBatch(frames: frames,
                                                   source: .mix(URL(fileURLWithPath: "/x")),
                                                   duration_s: 0.16)) { error in
            guard case EngineError.contractViolation(let message) = error else {
                XCTFail("wrong error: \(error)")
                return
            }
            XCTAssertTrue(message.contains("off the C-2.4 grid"))
        }
    }

    // MARK: - (2) The grader's comparison — the C-20 §4 sign, pinned

    func testTheLatencyOffsetSignMatchesTheContract() throws {
        // Two seconds of tone: the grid (125 frames) must cover the whole
        // ±50 ms window around every probed time — no end-of-grid clamping.
        let samples = audio(silence_s: 0.0, tone_s: 2.0)
        let batch = try buildBatch(samples)
        XCTAssertEqual(batch.frames.count, 125)

        // A live frame at t = 1.000 s with NO offset grades against t = 1.000.
        // (NOTE: the 16 ms grid never lands exactly on 1.000 — 1.000/0.016 =
        // 62.5 — so the window is the grid frames 0.944…1.040.)
        let zero = batch.frames(forLiveTime: 1.000, latencyOffset_ms: 0)
        XCTAssertEqual(zero.count, 7, "±50 ms at the 16 ms grid = 7 frames")
        XCTAssertTrue(zero.contains { abs($0.t - 0.992) < 1e-9 } && zero.contains { abs($0.t - 1.008) < 1e-9 },
                      "the nearest grid frames around 1.000 are in the window")
        let zeroMean = zero.map(\.t).reduce(0, +) / Double(zero.count)

        // C-20 §4: offset ≥ 0 = live is LATE → compare against the EARLIER
        // reference. An 80 ms offset shifts the comparison window 80 ms back
        // — EXACTLY, on the quantized grid.
        let offsetFrames = batch.frames(forLiveTime: 1.000, latencyOffset_ms: 80)
        let offsetMean = offsetFrames.map(\.t).reduce(0, +) / Double(offsetFrames.count)
        XCTAssertEqual(offsetMean - zeroMean, -0.080, accuracy: 1e-9,
                       "the window moved EARLIER by exactly the offset")

        // THE D-33 PIN: the same numbers through PlaybackTransform's helper —
        // one semantic, two surfaces, zero drift.
        let transform = PlaybackTransform(environment: .neutral)
        XCTAssertEqual(transform.referenceTime(forLiveTime: 1.000, latencyOffset_ms: 80),
                       0.920, accuracy: 1e-12)
        let viaTransform = batch.frames(nearReferenceTime:
            transform.referenceTime(forLiveTime: 1.000, latencyOffset_ms: 80))
        XCTAssertEqual(viaTransform, offsetFrames,
                       "the transform-mapped time and the batch helper agree exactly")

        // A negative offset (a device whose live path reads EARLY)
        // symmetrically shifts the comparison window LATER by +48 ms.
        let early = batch.frames(forLiveTime: 1.000, latencyOffset_ms: -48)
        let earlyMean = early.map(\.t).reduce(0, +) / Double(early.count)
        XCTAssertEqual(earlyMean - zeroMean, 0.048, accuracy: 1e-9)

        // Out of range: no frames near an unvoiced region — the caller's
        // `notAssessable`, never a fake miss.
        XCTAssertTrue(batch.frames(forLiveTime: 99.0, latencyOffset_ms: 0).isEmpty)
    }

    // MARK: - (3) The estimator split — the onset bias is STABLE, measured

    func testTheBatchVsRibbonOnsetBiasIsStableAndBounded() throws {
        // Two synthetic takes with the onset at DIFFERENT positions: the
        // batch (SwiftF0 grid) vs the ribbon (window-end causal). STABILITY
        // = the bias does not drift with the onset's position.
        func ribbonFirstVoicedTime(samples: [Float]) -> Double? {
            // THE RIBBON IS A 16 kHz PATH (RibbonSpec.sampleRate — the mic
            // path resamples upstream, P-104): the comparison feeds the SAME
            // 16 kHz audio SwiftF0's batch consumed, so both estimators sit
            // on one sample-density and one seconds axis.
            let audio16k = AudioResampler.resampleTo16k(samples: samples,
                                                        sourceRate: sampleRate)
            let engine = RibbonEngine()
            let frames = engine.push(audio16k)
            return frames.first { $0.hz > 80.0 }?.t
        }

        for (label, silence, tone) in [("early", 0.5, 1.5), ("late", 1.25, 1.5)] {
            let samples = audio(silence_s: silence, tone_s: tone)
            let batch = try buildBatch(samples)
            let batchOnset = try XCTUnwrap(batch.firstVoicedTime,
                                           "\(label): the batch voiced the tone")
            let ribbonOnset = try XCTUnwrap(ribbonFirstVoicedTime(samples: samples),
                                            "\(label): the ribbon voiced the tone")
            let bias = ribbonOnset - batchOnset
            // The ribbon's frame time is the WINDOW END (causal — 1024
            // samples @16 kHz = 64 ms), the batch's is the grid position, so
            // the ribbon reports the onset up to ~64 ms later, stable.
            XCTAssertGreaterThan(bias, -0.016,
                                 "\(label): the causal ribbon is never EARLIER than the grid")
            XCTAssertLessThanOrEqual(bias, 0.070,
                                     "\(label): the bias is the window-end semantics (≤ ~64 ms + one hop)")
            // Report the measured number for the row (honesty: it is a
            // RUNNER measurement of the ESTIMATOR bias, not device latency).
            print("P-401 onset bias (\(label)): batch \(batchOnset)s, ribbon \(ribbonOnset)s, bias \(bias * 1000) ms")
        }
    }

    // MARK: - The provenance label (the session's reproducibility record)

    func testTheSourceLabelIsTheProvenance() {
        XCTAssertEqual(GradingPitchSource.mix(URL(fileURLWithPath: "/b/mix.wav")).label,
                       "mix:mix.wav")
        XCTAssertEqual(GradingPitchSource.stem(part: .bass,
                                               url: URL(fileURLWithPath: "/b/BASS.m4a")).label,
                       "stem:BASS:BASS.m4a")
    }
}
