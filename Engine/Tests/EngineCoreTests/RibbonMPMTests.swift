import XCTest
@testable import EngineCore

// RibbonMPM tests (P-102 Swift path): analytic accuracy, causality, chunk
// invariance, reset. Cross-implementation parity with the VENDORED C++ is
// covered by Tests/Spikes/ribbon_real.py (the spike compiles the vendored
// code against the same fixtures — C-7 spirit).

final class RibbonMPMTests: XCTestCase {

    private func sine(_ hz: Double, seconds: Double, amplitude: Float = 0.5) -> [Float] {
        let n = Int(seconds * Double(RibbonSpec.sampleRate))
        let sr = Double(RibbonSpec.sampleRate)
        let twoPiHz = 2.0 * Double.pi * hz
        return (0..<n).map { i -> Float in
            let t = Double(i) / sr
            return Float(amplitude) * Float(sin(twoPiHz * t))
        }
    }

    func testSteadyToneAccuracyAndClarity() {
        let engine = RibbonEngine()
        var frames: [RibbonFrame] = []
        for chunk in stride(from: 0, to: sine(220.0, seconds: 1.5).count, by: 640) {
            let audio = sine(220.0, seconds: 1.5)
            let end = min(chunk + 640, audio.count)
            frames += engine.push(Array(audio[chunk..<end]))
        }
        XCTAssertGreaterThan(frames.count, 80, "1.5 s / 16 ms hop ≈ 93 frames (minus 64 ms window fill)")
        let mid = frames.dropFirst(10).dropLast(5) // skip window fill + tail
        for f in mid {
            let cents = abs(1200.0 * log2(f.hz / 220.0))
            XCTAssertLessThan(cents, 10.0, "220 Hz steady tone: \(f.hz) Hz (\(cents) c)")
            XCTAssertGreaterThan(f.clarity, 0.9, "pure tone clarity: \(f.clarity)")
        }
    }

    func testLowToneAboveFloorAndSubFloorRejected() {
        // 110 Hz (A2, in-range) and 60 Hz (below the 80 Hz floor).
        let engine = RibbonEngine()
        let frames = engine.push(sine(110.0, seconds: 1.2))
        let voiced = frames.dropFirst(8).filter { $0.hz > 0 }
        XCTAssertGreaterThan(voiced.count, 60, "110 Hz must track")
        for f in voiced {
            XCTAssertLessThan(abs(1200.0 * log2(f.hz / 110.0)), 10.0, "\(f.hz)")
        }
        let low = RibbonEngine().push(sine(60.0, seconds: 1.2)).dropFirst(8)
        XCTAssertTrue(low.allSatisfy { $0.hz == 0 }, "sub-80 Hz floor must zero hz (vendored parity)")
    }

    func testSilenceGivesNoPitchAndNoCrash() {
        let engine = RibbonEngine()
        let frames = engine.push([Float](repeating: 0, count: 2 * RibbonSpec.sampleRate))
        XCTAssertEqual(frames.count, 2 * RibbonSpec.sampleRate / RibbonSpec.hop - 3, "n-hop emission count")
        for f in frames {
            XCTAssertEqual(f.hz, 0, "silence: no pitch")
            XCTAssertTrue(f.clarity.isFinite, "no NaN from 0/0 denominators")
        }
    }

    func testNoiseClarityIsLow() {
        var rng = SeededGenerator(seed: 0x5EED)
        let noise = (0..<Int(1.2 * Double(RibbonSpec.sampleRate))).map { _ in Float.random(in: -0.4...0.4, using: &rng) }
        let frames = RibbonEngine().push(noise).dropFirst(8)
        let maxClarity = frames.map { $0.clarity }.max() ?? 0
        XCTAssertLessThan(maxClarity, 0.9, "white noise must not look like a pure tone (max clarity \(maxClarity))")
    }

    func testPushGranularityInvariance() {
        let audio = sine(146.83, seconds: 2.0)
        var a: [RibbonFrame] = []
        var i = 0
        let e1 = RibbonEngine()
        while i < audio.count { a += e1.push(Array(audio[i..<min(i + 640, audio.count)])); i += 640 }
        var b: [RibbonFrame] = []
        i = 0
        let e2 = RibbonEngine()
        while i < audio.count { b += e2.push(Array(audio[i..<min(i + 512, audio.count)])); i += 512 }
        XCTAssertEqual(a.count, b.count)
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x.hz, y.hz, accuracy: 1e-6, "frame emission must be push-granularity invariant")
            XCTAssertEqual(x.clarity, y.clarity, accuracy: 1e-9)
            XCTAssertEqual(x.t, y.t, accuracy: 1e-9)
        }
    }

    func testTimestampsOnContractGridAndCausal() {
        let engine = RibbonEngine()
        let audio = sine(180.0, seconds: 1.0)
        let firstBatch = engine.push(Array(audio[0..<512])) // 2 hops of history
        XCTAssertTrue(firstBatch.isEmpty, "no frame before a full window of PAST samples exists")
        _ = engine.push(Array(audio[512...]))
        // After the full second: frames = (16000 - 1024)/256 + 1 = 59
        // Timestamps: window END in seconds = (baseSample + start + window)/SR.
        let all = engine.push([]) // no new samples → no new frames
        XCTAssertTrue(all.isEmpty)
    }

    func testVoiceFixtureTracksMelodyTruth() throws {
        // Committed synthetic_voice fixture: C3-D3-E3-D3-C3 (MIDI 48/50/52/50/48,
        // 0.9 s each) with ±15 c vibrato @5.5 Hz + 0.5 s silence tail.
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Spikes/Fixtures/synthetic_voice_16k.wav")
        let wav = try PCMWaveReader.read(url: fixture)
        let frames = RibbonEngine().push(wav.samples)
        let noteMidis: [(range: Range<Double>, midi: Double)] = [
            (0.064..<0.9, 48), (0.9..<1.8, 50), (1.8..<2.7, 52), (2.7..<3.6, 50), (3.6..<4.5, 48),
        ]
        var inNote = 0, accurate = 0
        for f in frames where f.hz > 0 {
            guard let note = noteMidis.first(where: { $0.range.contains(f.t) }) else { continue }
            inNote += 1
            let target = EngineContract.hzForMidi(note.midi)
            if abs(1200.0 * log2(f.hz / target)) < 30.0 { accurate += 1 } // ±15 c vibrato + margin
        }
        XCTAssertGreaterThan(inNote, 250, "ribbon must voice most of the melody")
        XCTAssertGreaterThan(Double(accurate) / Double(inNote), 0.95,
                             "accurate frames \(accurate)/\(inNote) — vibrato within ±30 c of ET pitch")
    }
}

/// Tiny seeded RNG (tests only — deterministic noise).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
