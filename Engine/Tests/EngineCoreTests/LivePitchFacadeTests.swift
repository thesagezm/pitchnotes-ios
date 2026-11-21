import XCTest
@testable import EngineCore

// P-105 LivePitchEngine facade tests (CONTRACTS v0.1 C-6/C-6.1):
// - synthetic-stream AC: ribbon frames carry engine_id/lookahead_ms, hz
//   accurate on a steady tone, VAD gate fusion (closed ⇒ hz=0, confidence
//   keeps clarity), sticky sub-hop, reset, defensive non-16k handling;
// - C-6.1 preset table VERBATIM + calibration band math (presets immutable);
// - grading source tagging (SWIFTF0 / 176 ms) + band validation + decode;
// - PitchFrame v0.0 (keys absent) vs v0.1 round-trip compatibility.

final class LivePitchFacadeTests: XCTestCase {

    // MARK: - Mock seams

    /// Constant neural output (deterministic; facade tests assert TAGGING and
    /// plumbing, tone accuracy is the ribbon's job — accuracy lives in test 1).
    struct ConstantInference: SwiftF0Inference {
        let pitch: Double
        let confidence: Float
        func run(audio: [Float], fmin: Float, fmax: Float) throws -> (pitch: [Double], confidence: [Float]) {
            let n = audio.count / SwiftF0Spec.hop
            return (pitch: [Double](repeating: pitch, count: n),
                    confidence: [Float](repeating: confidence, count: n))
        }
    }

    /// Fixed-probability Silero VAD (passes state through unchanged).
    struct FixedVAD: SileroVADInference {
        let prob: Float
        func run(input: [Float], state: [Float], sampleRate: Int) throws -> (prob: Float, newState: [Float]) {
            (prob, state)
        }
    }

    /// Always-throws VAD (fail-open path).
    struct BrokenVAD: SileroVADInference {
        func run(input: [Float], state: [Float], sampleRate: Int) throws -> (prob: Float, newState: [Float]) {
            throw EngineError.modelMissing("broken VAD (test)")
        }
    }

    // MARK: - Helpers

    private func sine(_ hz: Double, seconds: Double, amplitude: Float = 0.5) -> [Float] {
        let n = Int(seconds * Double(RibbonSpec.sampleRate))
        let sr = Double(RibbonSpec.sampleRate)
        return (0..<n).map { i -> Float in
            Float(amplitude) * Float(sin(2.0 * .pi * hz * Double(i) / sr))
        }
    }

    private func pushChunks(_ facade: LivePitchFacade, _ audio: [Float], chunkSize: Int = 640) -> [PitchFrame] {
        var out: [PitchFrame] = []
        var i = 0
        while i < audio.count {
            let end = min(i + chunkSize, audio.count)
            let chunk = MicChunk(samples: Array(audio[i..<end]),
                                 sampleRate: RibbonSpec.sampleRate,
                                 captureTime_s: Double(end) / Double(RibbonSpec.sampleRate))
            out.append(facade.ribbonFrame(chunk))
            i = end
        }
        return out
    }

    private func cents(_ f: Double, _ ref: Double) -> Double {
        1200.0 * log2(f / ref)
    }

    // MARK: - C-6.0 ribbon source (synthetic-stream AC)

    func testRibbonFramesCarryProvenanceAndAccuracy() {
        let facade = LivePitchFacade(swiftf0Inference: ConstantInference(pitch: 0, confidence: 0))
        let frames = pushChunks(facade, sine(220.0, seconds: 1.5))
        XCTAssertGreaterThan(frames.count, 30, "1.5 s in 640-sample pushes ⇒ ~36 ribbon answers")

        for f in frames {
            XCTAssertEqual(f.engine_id, PitchEngineID.ribbonMpmYin.rawValue)
            XCTAssertEqual(f.lookahead_ms, 0, "ribbon is causal, zero lookahead")
            XCTAssertEqual(f.confidence, f.confidence.clamped01(), "confidence in [0,1]")
            XCTAssertGreaterThanOrEqual(f.loudness_db, -120)
            XCTAssertLessThanOrEqual(f.loudness_db, 0)
        }
        // Grid: every timestamp sits on the 16 ms hop grid (±1 µs float slop).
        for f in frames where f.hz > 0 {
            let hops = f.t / EngineContract.hopSeconds
            XCTAssertLessThan(abs(hops - hops.rounded()), 0.001, "t off the 16 ms grid: \(f.t)")
        }
        // Accuracy: skip window fill, steady 220 Hz within 10 cents, high clarity.
        let mid = frames.dropFirst(8).filter { $0.hz > 0 }
        XCTAssertGreaterThan(mid.count, 25)
        for f in mid {
            XCTAssertLessThan(abs(cents(f.hz, 220.0)), 10.0, "220 Hz tone: \(f.hz) Hz")
            XCTAssertGreaterThan(f.confidence, 0.9, "pure tone clarity: \(f.confidence)")
        }
        // Loudness is a real measurement of the 0.5-amplitude sine (~ -9 dBFS).
        XCTAssertGreaterThan(mid.first!.loudness_db, -30)
    }

    func testVADGateFusionClosedOpenAndFailOpen() {
        let tone = sine(220.0, seconds: 1.0)
        let baseline = pushChunks(LivePitchFacade(swiftf0Inference: ConstantInference(pitch: 0, confidence: 0)), tone)

        // Gate CLOSED (prob 0.0): hz forced to 0, confidence KEEPS the ribbon
        // clarity (C-6 handoff semantics — the UI can still show certainty).
        let closed = pushChunks(LivePitchFacade(swiftf0Inference: ConstantInference(pitch: 0, confidence: 0),
                                                vadInference: FixedVAD(prob: 0.0)), tone)
        XCTAssertEqual(baseline.count, closed.count)
        for (b, c) in zip(baseline, closed) {
            XCTAssertEqual(c.hz, 0, "closed gate must zero hz")
            XCTAssertEqual(c.confidence, b.confidence, accuracy: 1e-12, "clarity survives the gate")
            XCTAssertEqual(c.engine_id, PitchEngineID.ribbonMpmYin.rawValue)
            XCTAssertEqual(c.lookahead_ms, 0)
        }

        // Gate OPEN (prob 1.0): identical to the ungated baseline.
        let open = pushChunks(LivePitchFacade(swiftf0Inference: ConstantInference(pitch: 0, confidence: 0),
                                              vadInference: FixedVAD(prob: 1.0)), tone)
        for (b, o) in zip(baseline, open) {
            XCTAssertEqual(o.hz, b.hz, accuracy: 1e-12)
            XCTAssertEqual(o.confidence, b.confidence, accuracy: 1e-12)
        }

        // Broken VAD: fail OPEN (a broken gate must never kill the ribbon).
        let failed = pushChunks(LivePitchFacade(swiftf0Inference: ConstantInference(pitch: 0, confidence: 0),
                                                vadInference: BrokenVAD()), tone)
        for (b, f) in zip(baseline, failed) {
            XCTAssertEqual(f.hz, b.hz, accuracy: 1e-12)
            XCTAssertEqual(f.confidence, b.confidence, accuracy: 1e-12)
        }
    }

    func testSubHopStickyAndReset() {
        let facade = LivePitchFacade(swiftf0Inference: ConstantInference(pitch: 0, confidence: 0))
        let placeholder = facade.ribbonFrame(MicChunk(samples: [Float](repeating: 0.3, count: 100),
                                                      sampleRate: 16000, captureTime_s: 0.00625))
        XCTAssertEqual(placeholder.hz, 0, "no window of past samples yet ⇒ unvoiced")
        XCTAssertEqual(placeholder.confidence, 0)
        XCTAssertEqual(placeholder.engine_id, PitchEngineID.ribbonMpmYin.rawValue)
        XCTAssertEqual(placeholder.lookahead_ms, 0)

        // Cross the window + one hop: a real frame appears.
        let voicedChunk = sine(220.0, seconds: 0.0625) // 1000 samples
        let real = facade.ribbonFrame(MicChunk(samples: voicedChunk, sampleRate: 16000, captureTime_s: 0.06875))
        XCTAssertGreaterThan(real.hz, 0)

        // Sub-hop push: sticky — the exact previous frame comes back.
        let sticky = facade.ribbonFrame(MicChunk(samples: [Float](repeating: 0.3, count: 50),
                                                 sampleRate: 16000, captureTime_s: 0.1))
        XCTAssertEqual(sticky, real, "sub-hop push returns the previous frame unchanged")

        // Interruption reset: gate state, ribbon history, and sticky frame clear.
        facade.reset()
        let afterReset = facade.ribbonFrame(MicChunk(samples: [Float](repeating: 0.3, count: 50),
                                                     sampleRate: 16000, captureTime_s: 0.2))
        XCTAssertEqual(afterReset.hz, 0, "reset clears the sticky frame ⇒ placeholder again")
        XCTAssertEqual(afterReset.confidence, 0)
    }

    func testNon16kChunkIsDefensiveUnvoiced() {
        let facade = LivePitchFacade(swiftf0Inference: ConstantInference(pitch: 0, confidence: 0))
        let bad = facade.ribbonFrame(MicChunk(samples: [Float](repeating: 0.3, count: 512),
                                              sampleRate: 44100, captureTime_s: 0.01))
        XCTAssertEqual(bad.hz, 0, "non-contract sample rate must not reach the state machine")
        XCTAssertEqual(bad.engine_id, PitchEngineID.ribbonMpmYin.rawValue)
        // Engine untouched: a normal 16 kHz push afterwards still works.
        let good = pushChunks(facade, sine(220.0, seconds: 1.0))
        XCTAssertGreaterThan(good.filter { $0.hz > 0 }.count, 20)
    }

    // MARK: - C-6.0 grading source

    func testGradingFramesTaggedGridAndErrors() async throws {
        // Real WAV through the real decode → SwiftF0Batch plumbing (constant
        // inference ⇒ deterministic frames; tagging is what's under test).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p105-grading-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wavURL = dir.appendingPathComponent("mock-mix.wav")
        try MockEngine.wavData(for: .bass, scenario: .perfect, seed: 0x5017).write(to: wavURL)
        let audio = DecodedAudio(url: wavURL, sampleRate: 44100, channels: 1, duration_s: 12.0)

        let facade = LivePitchFacade(swiftf0Inference: ConstantInference(pitch: 0, confidence: 1.0))
        var frames: [PitchFrame] = []
        for try await f in try await facade.gradingFrames(audio, fmin_hz: 80, fmax_hz: 700) {
            frames.append(f)
        }
        XCTAssertEqual(frames.count, 750, "12 s on the 16 ms grid")
        for f in frames {
            XCTAssertEqual(f.engine_id, PitchEngineID.swiftf0.rawValue)
            XCTAssertEqual(f.lookahead_ms, LivePitchFacade.gradingLookaheadMs)
            XCTAssertEqual(f.lookahead_ms, 176, "C-6 contract value")
            XCTAssertEqual(f.hz, 0, "constant zero-pitch inference ⇒ unvoiced frames")
        }
        for (i, f) in frames.enumerated() {
            XCTAssertEqual(f.t, Double(i) * EngineContract.hopSeconds, accuracy: 0.001, "V13 grid")
        }

        // EngineAPI pitchFrames delegates to the same tagged grading stream.
        var viaBase = 0
        for try await f in try await facade.pitchFrames(audio, fmin: 80, fmax: 700) {
            XCTAssertEqual(f.engine_id, PitchEngineID.swiftf0.rawValue)
            viaBase += 1
        }
        XCTAssertEqual(viaBase, 750)

        // Band validation + unsupported decode → contract errors, not crashes.
        do {
            _ = try await facade.gradingFrames(audio, fmin_hz: 200, fmax_hz: 100)
            XCTFail("inverted band must throw")
        } catch let EngineError.contractViolation(msg) {
            XCTAssertTrue(msg.contains("fmin_hz"))
        }
        let junk = dir.appendingPathComponent("junk.wav")
        try Data("definitely not a wav".utf8).write(to: junk)
        do {
            _ = try await facade.gradingFrames(DecodedAudio(url: junk, sampleRate: 44100, channels: 1, duration_s: 1),
                                               fmin_hz: 80, fmax_hz: 700)
            XCTFail("non-WAV must throw unsupportedFormat")
        } catch is EngineError {}

        // M2 stubs throw honest errors (MockEngine covers these flows for Jess).
        do {
            _ = try await facade.importAudio(url: wavURL)
            XCTFail("importAudio is M2 scope")
        } catch is EngineError {}
        do {
            _ = try await facade.separate(audio, mode: .twoStem)
            XCTFail("separate is M2 scope")
        } catch is EngineError {}
        do {
            _ = try await facade.noteTrack(.mix(wavURL), part: .bass)
            XCTFail("noteTrack is M2/M3 scope")
        } catch is EngineError {}
    }

    // MARK: - C-6.1 presets (table verbatim + calibration)

    func testPresetsTableVerbatimC61() {
        // (part, midiLow, midiHigh, fmin, fmax) — UX §3.6 / CONTRACTS C-6.1.
        let table: [(Part, Int, Int, Double, Double)] = [
            (.bass,      40, 55, 82.4, 196.0),
            (.baritone,  45, 62, 110.0, 293.7),
            (.baritenor, 48, 65, 130.8, 349.2),
            (.t2,        52, 69, 164.8, 440.0),
            (.t1,        55, 76, 196.0, 659.3),
            (.soprano,   60, 79, 261.6, 784.0),
            (.alto,      55, 74, 196.0, 587.3),
        ]
        XCTAssertEqual(PartRangePresets.all.count, 7, "C-6.1 has exactly seven presets")
        for (part, lo, hi, fmin, fmax) in table {
            let p = PartRangePresets.preset(for: part)
            XCTAssertNotNil(p, "missing preset for \(part.rawValue)")
            XCTAssertEqual(p?.midiLow, lo, "\(part.rawValue) midiLow")
            XCTAssertEqual(p?.midiHigh, hi, "\(part.rawValue) midiHigh")
            XCTAssertEqual(p?.fmin ?? -1, fmin, accuracy: 0.05, "\(part.rawValue) fmin")
            XCTAssertEqual(p?.fmax ?? -1, fmax, accuracy: 0.05, "\(part.rawValue) fmax")
            // Hz bounds are the preset MIDI bounds under A440 (self-consistent).
            XCTAssertEqual(p?.fmin ?? -1, EngineContract.hzForMidi(Double(lo)), accuracy: 0.05)
            XCTAssertEqual(p?.fmax ?? -1, EngineContract.hzForMidi(Double(hi)), accuracy: 0.05)
        }
        // Non-singable parts carry no preset.
        XCTAssertNil(PartRangePresets.preset(for: .vp))
        XCTAssertNil(PartRangePresets.preset(for: .lead))
        XCTAssertNil(PartRangePresets.preset(for: .instrumental))
    }

    func testCalibratedBandShiftsClampsAndKeepsTableFixed() {
        // Zero calibration == the preset MIDI bounds at full precision.
        let bass = PartRangePresets.calibratedBand(for: .bass, nudgeSemitones: 0)!
        XCTAssertEqual(bass.fmin, EngineContract.hzForMidi(40), accuracy: 1e-9)
        XCTAssertEqual(bass.fmax, EngineContract.hzForMidi(55), accuracy: 1e-9)

        // +1 semitone nudge shifts BOTH bounds up one key.
        let up = PartRangePresets.calibratedBand(for: .bass, nudgeSemitones: 1)!
        XCTAssertEqual(up.fmin, EngineContract.hzForMidi(41), accuracy: 1e-9)
        XCTAssertEqual(up.fmax, EngineContract.hzForMidi(56), accuracy: 1e-9)

        // Nudge clamps to −2…+2 (contract).
        XCTAssertEqual(PartRangePresets.clampNudge(5), 2)
        XCTAssertEqual(PartRangePresets.clampNudge(-9), -2)
        XCTAssertEqual(PartRangePresets.clampNudge(0), 0)
        let clamped = PartRangePresets.calibratedBand(for: .bass, nudgeSemitones: 7)!
        XCTAssertEqual(clamped.fmin, EngineContract.hzForMidi(42), accuracy: 1e-9)

        // Mic-profile offset in cents: +25 c scales both bounds sharp.
        let detuned = PartRangePresets.calibratedBand(for: .bass, nudgeSemitones: 0, micOffsetCents: 25)!
        XCTAssertEqual(detuned.fmin, EngineContract.detune(hz: EngineContract.hzForMidi(40), cents: 25), accuracy: 1e-9)
        XCTAssertEqual(detuned.fmax, EngineContract.detune(hz: EngineContract.hzForMidi(55), cents: 25), accuracy: 1e-9)

        // The preset TABLE is fixed contract data — calibration never mutates it.
        XCTAssertEqual(PartRangePresets.preset(for: .bass)!.midiLow, 40)
        XCTAssertEqual(PartRangePresets.preset(for: .bass)!.midiHigh, 55)

        // Non-preset parts have nothing to calibrate.
        XCTAssertNil(PartRangePresets.calibratedBand(for: .vp, nudgeSemitones: 1))
    }

    // MARK: - MockEngine facade conformance (Jess's swap surface, C-6.0)

    func testMockEngineFacadeTaggingAndBanding() async throws {
        let mock = MockEngine(scenario: .perfect, referencePart: .bass)
        XCTAssertEqual(mock.ribbonSource, .ribbonMpmYin)
        XCTAssertEqual(mock.gradingSource, .swiftf0)

        // RibbonFrame == livePitch values, re-tagged causal.
        let chunk = MicChunk(samples: [Float](repeating: 0, count: 320),
                             sampleRate: 16000, captureTime_s: 0.5)
        let ribbon = mock.ribbonFrame(chunk)
        let base = mock.livePitch(chunk)
        XCTAssertEqual(ribbon.t, base.t)
        XCTAssertEqual(ribbon.hz, base.hz)
        XCTAssertEqual(ribbon.confidence, base.confidence)
        XCTAssertEqual(ribbon.engine_id, PitchEngineID.ribbonMpmYin.rawValue)
        XCTAssertEqual(ribbon.lookahead_ms, 0)

        // GradingFrames: tagged SWIFTF0/176; C-6.1 BASS band filters the mock
        // script (F2 87.3 Hz and G2 98 Hz fall outside a 100–150 Hz band).
        let audio = DecodedAudio(url: mock.bundleDirectory.appendingPathComponent("mix.wav"),
                                 sampleRate: 44100, channels: 1, duration_s: MockEngine.duration_s)
        var voiced = 0
        for try await f in try await mock.gradingFrames(audio, fmin_hz: 100, fmax_hz: 150) {
            XCTAssertEqual(f.engine_id, PitchEngineID.swiftf0.rawValue)
            XCTAssertEqual(f.lookahead_ms, LivePitchFacade.gradingLookaheadMs)
            if f.hz > 0 {
                voiced += 1
                XCTAssertGreaterThanOrEqual(f.hz, 100)
                XCTAssertLessThanOrEqual(f.hz, 150)
            }
        }
        XCTAssertGreaterThan(voiced, 0, "C3 (130.8) + A2 (110) notes survive the band")
    }

    // MARK: - PitchFrame v0.0 / v0.1 JSON compatibility

    func testPitchFrameV00V01JSONCompat() throws {
        let decoder = JSONDecoder()

        // v0.0 shape: the four original keys ONLY — engine_id/lookahead_ms
        // decode as nil (treated as ("", 0): unknown engine, causal).
        let v00 = Data(#"{"t":0.016,"hz":220.0,"confidence":0.9,"loudness_db":-30.0}"#.utf8)
        let old = try decoder.decode(PitchFrame.self, from: v00)
        XCTAssertNil(old.engine_id)
        XCTAssertNil(old.lookahead_ms)
        XCTAssertEqual(old.hz, 220.0)

        // v0.1: provenance keys present — full round-trip equality.
        let newer = PitchFrame(t: 0.016, hz: 440.0, confidence: 0.8, loudness_db: -20.0,
                               engine_id: PitchEngineID.swiftf0.rawValue, lookahead_ms: 176)
        let data = try JSONEncoder().encode(newer)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"engine_id\""), "v0.1 keys must serialize")
        XCTAssertTrue(json.contains("\"lookahead_ms\""))
        let round = try decoder.decode(PitchFrame.self, from: data)
        XCTAssertEqual(round, newer)

        // A v0.1 PitchFramesFile decodes v0.0 frame arrays unchanged
        // (no new V-rule; validators must not require the new keys).
        let fileJSON = Data(#"""
        {"contractVersion":"v0.0","part":"BASS","hopMs":16,"frames":[
          {"t":0.0,"hz":0.0,"confidence":0.0,"loudness_db":-120.0},
          {"t":0.016,"hz":110.0,"confidence":0.9,"loudness_db":-28.0,
           "engine_id":"RIBBON_MPM_YIN","lookahead_ms":0}]}
        """#.utf8)
        let mixed = try decoder.decode(PitchFramesFile.self, from: fileJSON)
        XCTAssertEqual(mixed.frames.count, 2)
        XCTAssertNil(mixed.frames[0].engine_id, "v0.0 frame in a v0.1 file: keys absent")
        XCTAssertEqual(mixed.frames[1].engine_id, PitchEngineID.ribbonMpmYin.rawValue)
        XCTAssertEqual(mixed.frames[1].lookahead_ms, 0)
    }
}

private extension Double {
    func clamped01() -> Double { min(1.0, max(0.0, self)) }
}
