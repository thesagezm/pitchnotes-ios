import Foundation
import XCTest
@testable import EngineCore

// P-207 · Tuning estimator tests (D-22). Deterministic synthetic signals —
// the estimator must recover a detuning of ±35 cents within ±5 cents (AC),
// return 0 for in-tune / weak signals, and never touch the samples
// (read-only math; D-22 "stored audio is NEVER resampled/retuned").

final class TuningEstimatorTests: XCTestCase {

    /// Multi-note melody with voice-ish harmonics, optionally detuned by
    /// `cents` (all notes shifted by the SAME offset — the systematic
    /// tape/varispeed detuning D-22 targets).
    private func melody(cents: Double, notes: [Double] = [440.0, 329.63, 392.0, 440.0],
                        noteDur: Double = 0.9, sr: Int = 44100, amp: Float = 0.35) -> [Float] {
        let n = Int(Double(sr) * Double(notes.count) * noteDur)
        var buf = [Float](repeating: 0, count: n)
        let detune = pow(2.0, cents / 1200.0)
        for (k, f0) in notes.enumerated() {
            let f = f0 * detune
            let start = Int(Double(k) * noteDur * Double(sr))
            let len = min(Int(noteDur * Double(sr)), n - start)
            for i in 0..<len {
                let t = Double(i) / Double(sr)
                let v = 1.0 * sin(2.0 * .pi * f * t)
                    + 0.5 * sin(2.0 * .pi * 2.0 * f * t)
                    + 0.25 * sin(2.0 * .pi * 3.0 * f * t)
                let fade = min(200, len)
                let env: Double = i < fade ? Double(i) / Double(fade)
                    : i > len - fade ? Double(len - i) / Double(fade) : 1.0
                buf[start + i] += amp * Float(v * env)
            }
        }
        return buf
    }

    private func vibrato(carrierHz: Double, centsDepth: Double, rateHz: Double,
                         dur: Double, sr: Int = 44100) -> [Float] {
        let n = Int(Double(sr) * dur)
        var buf = [Float](repeating: 0, count: n)
        // Phase-integrated vibrato so the instantaneous frequency is exact.
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / Double(sr)
            let f = carrierHz * pow(2.0, centsDepth * sin(2.0 * .pi * rateHz * t) / 1200.0)
            phase += 2.0 * .pi * f / Double(sr)
            let v = 1.0 * sin(phase) + 0.5 * sin(2.0 * phase) + 0.25 * sin(3.0 * phase)
            let env: Double = t < 0.05 ? t / 0.05 : (t > dur - 0.05 ? (dur - t) / 0.05 : 1.0)
            buf[i] = 0.35 * Float(v * max(0.0, min(1.0, env)))
        }
        return buf
    }

    // MARK: - AC: detuned fixtures recover within ±5 c

    /// Committed fixture (Tests/Spikes/Fixtures, P-001-pinned) — repo-root
    /// relative, same pattern as the other fixture tests.
    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // EngineCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Engine
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Tests/Spikes/Fixtures/\(name)")
    }

    /// THE AC, against the COMMITTED fixtures: whole mixture at ±35 c (P-207
    /// gen.py variants). PCMWaveReader decodes the PCM16 fixture; the
    /// estimator is scale-invariant.
    func testCommittedDetunedPlus35FixtureRecoversWithin5c() throws {
        let content = try PCMWaveReader.read(url: fixtureURL("mix44k_detuned_plus35.wav"))
        XCTAssertEqual(content.sampleRate, 44100)
        let est = TuningEstimator().estimate(samples: content.samples,
                                             sampleRate: content.sampleRate)
        XCTAssertTrue((30...40).contains(est), "committed +35 fixture expected ~+35, got \(est)")
    }

    func testCommittedDetunedMinus35FixtureRecoversWithin5c() throws {
        let content = try PCMWaveReader.read(url: fixtureURL("mix44k_detuned_minus35.wav"))
        let est = TuningEstimator().estimate(samples: content.samples,
                                             sampleRate: content.sampleRate)
        XCTAssertTrue((-40...(-30)).contains(est), "committed −35 fixture expected ~−35, got \(est)")
    }

    func testDetunedPlus35RecoversWithin5c() {
        let est = TuningEstimator().estimate(samples: melody(cents: 35), sampleRate: 44100)
        XCTAssertTrue((30...40).contains(est), "expected ~+35, got \(est)")
    }

    func testDetunedMinus35RecoversWithin5c() {
        let est = TuningEstimator().estimate(samples: melody(cents: -35), sampleRate: 44100)
        XCTAssertTrue((-40...(-30)).contains(est), "expected ~−35, got \(est)")
    }

    func testDetunedPlus49StaysInsideClamp() {
        let est = TuningEstimator().estimate(samples: melody(cents: 49), sampleRate: 44100)
        XCTAssertTrue((44...50).contains(est), "expected ~+49, got \(est)")
    }

    /// +120 c = one semitone plus 20 c → nearest-note deviation is +20.
    func testSemitonePlus20MeasuresRelativeToNearestNote() {
        let est = TuningEstimator().estimate(samples: melody(cents: 120), sampleRate: 44100)
        XCTAssertTrue((15...25).contains(est), "expected ~+20 relative to nearest note, got \(est)")
    }

    // MARK: - Zero results (in-tune / weak)

    func testInTuneReturnsZero() {
        XCTAssertEqual(TuningEstimator().estimate(samples: melody(cents: 0), sampleRate: 44100), 0)
    }

    func testVibratoDoesNotBiasInTuneMean() {
        let est = TuningEstimator().estimate(samples: vibrato(carrierHz: 440, centsDepth: 15, rateHz: 5.5, dur: 3.0),
                                             sampleRate: 44100)
        XCTAssertEqual(est, 0, "zero-mean vibrato must not bias the mean")
    }

    func testVibratoCarrierDetuneStillRecovers() {
        let est = TuningEstimator().estimate(samples: vibrato(carrierHz: 440 * pow(2.0, 35.0 / 1200.0),
                                                              centsDepth: 15, rateHz: 5.5, dur: 3.0),
                                             sampleRate: 44100)
        XCTAssertTrue((30...40).contains(est), "vibrato carrier detune ~+35 expected, got \(est)")
    }

    func testTooFewFramesReturnsZero() {
        // 0.3 s tone → under minRefinedFrames (25) after edge-window trimming.
        let est = TuningEstimator().estimate(samples: melody(cents: 35, notes: [440.0], noteDur: 0.3),
                                             sampleRate: 44100)
        XCTAssertEqual(est, 0, "weak signal must default to 0 per D-22")
    }

    func testSilenceReturnsZero() {
        XCTAssertEqual(TuningEstimator().estimate(samples: [Float](repeating: 0, count: 44100 * 3),
                                                   sampleRate: 44100), 0)
    }

    // MARK: - Circular mean (pure math)

    func testCircularMeanBasicCluster() {
        let (mean, conc) = TuningEstimator.circularMean([30, 34, 32, 31, 33])
        XCTAssertEqual(mean, 32.0, accuracy: 0.5)
        XCTAssertGreaterThan(conc, 0.99)
    }

    func testCircularMeanHandlesWrapBoundary() {
        // Cluster near +50 must NOT fold across 0 into a near-zero mean.
        let (mean, conc) = TuningEstimator.circularMean([49.9, 49.8, 49.7, 49.9])
        XCTAssertEqual(mean, 49.8, accuracy: 0.5)
        XCTAssertGreaterThan(conc, 0.99)
    }

    func testCircularMeanScatterHasLowConcentration() {
        let (_, conc) = TuningEstimator.circularMean([49, -49, 20, -20, 0])
        XCTAssertLessThan(conc, 0.55, "scattered deviations must fail the concentration gate")
    }

    // MARK: - External frame source (SwiftF0-frames API path)

    func testExternalFramesPathWithSyntheticContour() {
        // 16 kHz tone + a synthetic frame contour claiming A4+35c.
        let sr = 16000
        let n = sr * 3
        let f = 440.0 * pow(2.0, 35.0 / 1200.0)
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / Double(sr)
            samples[i] = 0.35 * Float(sin(2.0 * .pi * f * t)
                                      + 0.5 * sin(2.0 * .pi * 2 * f * t)
                                      + 0.25 * sin(2.0 * .pi * 3 * f * t))
        }
        // Frames every 16 ms claiming the DETUNED hz (as SwiftF0 would report).
        var frames: [TuningEstimator.Frame] = []
        for k in 0..<(n / 256) {
            frames.append(TuningEstimator.Frame(t: Double(k) * 256.0 / Double(sr),
                                                hz: f, clarity: 0.95))
        }
        let est = TuningEstimator().estimate(samples16k: samples, frames: frames)
        XCTAssertTrue((30...40).contains(est), "external-frame path expected ~+35, got \(est)")
    }

    // MARK: - Pipeline integration (auto-estimate + explicit override)

    private func writePcm16Wav(url: URL, samples: [Float], sampleRate: Int) throws {
        var data = Data()
        func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        var payload = Data()
        for f in samples {
            let v = Int16(max(-32768, min(32767, Int(f * 32767.0)))).littleEndian
            withUnsafeBytes(of: v) { payload.append(contentsOf: $0) }
        }
        ascii("RIFF"); u32(UInt32(36 + payload.count)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        ascii("data"); u32(UInt32(payload.count))
        data.append(payload)
        try data.write(to: url)
    }

    private func twoStemParts() -> [PartInfo] {
        [PartInfo(part: .vocals, stemFile: "stems/VOCALS.m4a", channels: 1, noteConfidence: 0.0),
         PartInfo(part: .instrumental, stemFile: "stems/INSTRUMENTAL.m4a", channels: 2, noteConfidence: 0.0)]
    }

    func testPipelineAutoEstimatesDetunedTuning() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("p207-auto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("detuned35.wav")
        try writePcm16Wav(url: src, samples: melody(cents: 35), sampleRate: 44100)

        // tuningCents omitted → nil → auto-estimate (P-207 slot).
        let result = try await ImportPipeline.run(source: src, title: "t", workDir: dir,
                                                  hasher: nil, decoder: WavSourceDecoder(),
                                                  emitter: nil, parts: twoStemParts())
        let cents = try XCTUnwrap(result.manifest.tuning_cents, "v1.0 manifest must carry tuning_cents")
        XCTAssertTrue((30...40).contains(cents),
                      "pipeline auto-estimate expected ~+35, got \(cents)")
        XCTAssertTrue(BundleValidator.validate(manifest: result.manifest).isValid)
    }

    func testPipelineExplicitTuningOverridesEstimator() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("p207-override-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("detuned35.wav")
        try writePcm16Wav(url: src, samples: melody(cents: 35), sampleRate: 44100)

        let result = try await ImportPipeline.run(source: src, title: "t", workDir: dir,
                                                  hasher: nil, decoder: WavSourceDecoder(),
                                                  emitter: nil, tuningCents: 7,
                                                  parts: twoStemParts())
        XCTAssertEqual(result.manifest.tuning_cents, 7, "explicit value must override the estimator")
    }
}
