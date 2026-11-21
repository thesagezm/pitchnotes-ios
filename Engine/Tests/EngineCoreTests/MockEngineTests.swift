import XCTest
@testable import EngineCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// MockEngine determinism, scenario semantics, and contract-validity tests.
/// Async EngineAPI calls are bridged to sync via `awaitSync` so the same tests
/// run under swift-corelibs-xctest (Linux) and macOS XCTest.
final class MockEngineTests: XCTestCase {

    // MARK: - Async bridge (corelibs-xctest compatibility)

    private func awaitSync<T>(_ body: @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<T, Error>?
        Task {
            do { outcome = .success(try await body()) }
            catch { outcome = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try outcome!.get()
    }

    private func tempDir(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("enginecore-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - All scenarios produce contract-valid output (P-001 AC)

    func testAllScenariosProduceContractValidOutput() throws {
        for scenario in MockScenario.allCases {
            let engine = MockEngine(scenario: scenario, seed: 7)
            for part in MockEngine.scriptedParts {
                let track = engine.noteTrack(for: part)
                XCTAssertTrue(BundleValidator.validate(noteTrack: track).isValid,
                              "scenario \(scenario.rawValue) part \(part.rawValue): \(BundleValidator.validate(noteTrack: track).violations)")
                let frames = engine.frames(for: part, fmin: 0, fmax: .infinity)
                let file = PitchFramesFile(part: part, frames: frames)
                XCTAssertTrue(BundleValidator.validate(pitchFrames: file).isValid,
                              "scenario \(scenario.rawValue) part \(part.rawValue): \(BundleValidator.validate(pitchFrames: file).violations)")
            }
        }
    }

    func testBundleOnDiskPassesV1toV13ForAllScenarios() throws {
        for scenario in MockScenario.allCases {
            let engine = MockEngine(scenario: scenario, seed: 7)
            let dir = tempDir("bundle-\(scenario.rawValue)")
            defer { try? FileManager.default.removeItem(at: dir) }
            _ = try engine.makeBundle(to: dir)
            let result = BundleValidator.validate(bundleDirectory: dir)
            XCTAssertTrue(result.isValid, "scenario \(scenario.rawValue): \(result.violations)")
        }
    }

    func testSeparateWritesBundleAndReturnsStemURLs() throws {
        try awaitSync {
            let engine = MockEngine(scenario: .perfect, seed: 3)
            let dir = self.tempDir("separate")
            defer { try? FileManager.default.removeItem(at: dir) }
            let audio = try await engine.importAudio(url: URL(fileURLWithPath: #filePath))
            let stems = try await engine.separate(audio, mode: .twoStem)
            XCTAssertEqual(stems.count, 5) // five voice parts, acapella mock (D-9)
            for (part, url) in stems {
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), part.rawValue)
                XCTAssertTrue(url.path.hasSuffix("\(part.rawValue).wav"))
            }
            let manifest = try engine.makeBundle(to: dir)
            XCTAssertFalse(manifest.hasInstrumental)
            return ()
        }
    }

    /// Test-side re-derivation of the expected hz for a voiced frame at grid time
    /// t (nil when not exactly-checkable: silent/breathy jitter, or off-note frame).
    private func expectedHz(at t: Double, scenario: MockScenario) -> Double? {
        if scenario == .silent || scenario == .breathy { return nil }
        for sn in MockEngine.script[.bass] ?? [] {
            var effStart = sn.start_s
            if scenario == .lateOnset { effStart += 0.12 }
            if t >= effStart && t < sn.end_s {
                var midi = Double(sn.midi)
                if scenario == .octaveError { midi += 12 }
                let base = EngineContract.hzForMidi(midi)
                switch scenario {
                case .flat: return EngineContract.detune(hz: base, cents: -30.0)
                case .sharp: return EngineContract.detune(hz: base, cents: 35.0)
                case .vibrato: return EngineContract.detune(hz: base, cents: 25.0 * sin(2.0 * .pi * 5.5 * t))
                default: return base
                }
            }
        }
        return nil
    }

    /// Plain equal-tempered base hz for the active note at t (no scenario cents) —
    /// used for extent checks where the deviation itself is the quantity of interest.
    private func baseHz(at t: Double, scenario: MockScenario) -> Double? {
        if scenario == .silent || scenario == .breathy { return nil }
        for sn in MockEngine.script[.bass] ?? [] {
            var effStart = sn.start_s
            if scenario == .lateOnset { effStart += 0.12 }
            if t >= effStart && t < sn.end_s {
                var midi = Double(sn.midi)
                if scenario == .octaveError { midi += 12 }
                return EngineContract.hzForMidi(midi)
            }
        }
        return nil
    }

    private func assertPitchDeviation(_ engine: MockEngine, scenario: MockScenario,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let frames = engine.unfilteredFrames(for: .bass)
        let voiced = frames.filter { $0.hz > 0 }
        XCTAssertTrue(voiced.count > 500, "expected ~9.2 s voiced of 12 s", file: file, line: line)
        for f in voiced {
            let expected = XCTUnwrapHelper(expectedHz(at: f.t, scenario: scenario),
                                           "frame t=\(f.t) unexpectedly voiced", file: file, line: line)
            guard let expectedHzValue = expected else { continue }
            let cents = 1200.0 * log2(f.hz / expectedHzValue)
            XCTAssertEqual(cents, 0, accuracy: 0.001, "frame t=\(f.t) off expected pitch", file: file, line: line)
        }
    }

    private func XCTUnwrapHelper<T>(_ value: T?, _ message: String,
                                    file: StaticString = #filePath, line: UInt = #line) -> T? {
        if value == nil { XCTFail(message, file: file, line: line) }
        return value
    }

    func testPerfectScenarioIsOnPitch() throws {
        assertPitchDeviation(MockEngine(scenario: .perfect, seed: 1), scenario: .perfect)
    }

    func testFlatScenarioIs30CentsFlat() throws {
        let engine = MockEngine(scenario: .flat, seed: 1)
        let track = engine.noteTrack(for: .bass)
        XCTAssertTrue(track.notes.allSatisfy { $0.cents_ref == -30 })
        assertPitchDeviation(engine, scenario: .flat)
    }

    func testSharpScenarioIs35CentsSharp() throws {
        let engine = MockEngine(scenario: .sharp, seed: 1)
        let track = engine.noteTrack(for: .bass)
        XCTAssertTrue(track.notes.allSatisfy { $0.cents_ref == 35 })
        assertPitchDeviation(engine, scenario: .sharp)
    }

    func testOctaveErrorScenarioSingsTwelveSemitonesHigh() throws {
        let engine = MockEngine(scenario: .octaveError, seed: 1)
        let track = engine.noteTrack(for: .bass)
        XCTAssertEqual(track.notes.map(\.midi), [60, 57, 53, 55]) // +12 over [48, 45, 41, 43]
        assertPitchDeviation(engine, scenario: .octaveError)
    }

    func testVibratoScenarioOscillatesAroundTarget() throws {
        let engine = MockEngine(scenario: .vibrato, seed: 1)
        assertPitchDeviation(engine, scenario: .vibrato)
        // It actually oscillates: per-frame deviation from the ACTIVE note's
        // expected hz hits both extents and stays within the ±26 cent envelope.
        let deviations = engine.unfilteredFrames(for: .bass).filter { $0.hz > 0 }.compactMap { f -> Double? in
            guard let base = baseHz(at: f.t, scenario: .vibrato) else { return nil }
            return 1200.0 * log2(f.hz / base)
        }
        XCTAssertFalse(deviations.isEmpty)
        XCTAssertTrue(deviations.contains { $0 > 15.0 })
        XCTAssertTrue(deviations.contains { $0 < -15.0 })
        XCTAssertLessThanOrEqual(deviations.map(abs).max() ?? 0, 26.0)
    }

    func testSilentScenarioHasNoVoicedOutput() throws {
        let engine = MockEngine(scenario: .silent, seed: 1)
        let track = engine.noteTrack(for: .bass)
        XCTAssertTrue(track.notes.isEmpty)
        let frames = engine.unfilteredFrames(for: .bass)
        XCTAssertTrue(frames.allSatisfy { $0.hz == 0.0 && $0.confidence == 0.0 && $0.loudness_db == -120.0 })
    }

    func testBreathyScenarioIsLowConfidenceAndQuiet() throws {
        let engine = MockEngine(scenario: .breathy, seed: 1)
        let voiced = engine.unfilteredFrames(for: .bass).filter { $0.hz > 0 }
        XCTAssertTrue(voiced.count > 500)
        for f in voiced {
            XCTAssertTrue(f.confidence >= 0.15 && f.confidence <= 0.35, "confidence \(f.confidence)")
            XCTAssertTrue(f.loudness_db <= -40.0, "loudness \(f.loudness_db)")
        }
    }

    func testLateOnsetScenarioStarts120msLate() throws {
        let engine = MockEngine(scenario: .lateOnset, seed: 1)
        let track = engine.noteTrack(for: .bass)
        XCTAssertEqual(track.notes[0].start_s, 0.12, accuracy: 0.0001)
        XCTAssertEqual(track.notes[1].start_s, 3.12, accuracy: 0.0001)
        // Frame at nominal onset t=3.0 must be unvoiced; at 3.128 voiced.
        let frames = engine.unfilteredFrames(for: .bass)
        XCTAssertEqual(frames[Int(3.0 / 0.016)].hz, 0.0)
        XCTAssertGreaterThan(frames[Int(3.128 / 0.016)].hz, 0.0)
    }


    // MARK: - Determinism (P-001 AC: seeded + deterministic)

    func testSameSeedProducesIdenticalFramesAndTracks() throws {
        for scenario in MockScenario.allCases {
            let a = MockEngine(scenario: scenario, seed: 99)
            let b = MockEngine(scenario: scenario, seed: 99)
            for part in MockEngine.scriptedParts {
                XCTAssertEqual(a.unfilteredFrames(for: part), b.unfilteredFrames(for: part))
                XCTAssertEqual(a.noteTrack(for: part), b.noteTrack(for: part))
            }
        }
    }

    func testDifferentSeedProducesDifferentIdButSameScript() throws {
        let a = MockEngine(scenario: .perfect, seed: 1)
        let b = MockEngine(scenario: .perfect, seed: 2)
        XCTAssertNotEqual(a.songID, b.songID)
        XCTAssertEqual(a.noteTrack(for: .bass).notes.map(\.midi), b.noteTrack(for: .bass).notes.map(\.midi))
    }

    func testBundleRegenerationIsByteIdentical() throws {
        let engine = MockEngine(scenario: .perfect, seed: 5)
        let dirA = tempDir("regen-a")
        let dirB = tempDir("regen-b")
        defer { try? FileManager.default.removeItem(at: dirA); try? FileManager.default.removeItem(at: dirB) }
        _ = try engine.makeBundle(to: dirA)
        _ = try engine.makeBundle(to: dirB)

        let relativeFiles = ["song.json", "stems/BASS.wav", "stems/BARITONE.wav", "stems/BARITENOR.wav",
                             "stems/T2.wav", "stems/T1.wav", "notes/BASS.json", "pitch/BASS.json",
                             "notes/T1.json", "pitch/T1.json"]
        for rel in relativeFiles {
            let a = try Data(contentsOf: dirA.appendingPathComponent(rel))
            let b = try Data(contentsOf: dirB.appendingPathComponent(rel))
            XCTAssertEqual(a, b, "file \(rel) not byte-identical across regenerations")
        }
    }

    func testULIDFormat() throws {
        let id = MockEngine.ulid(seed: 11)
        XCTAssertEqual(id.count, 26)
        let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        XCTAssertTrue(id.allSatisfy { alphabet.contains($0) }, id)
    }

    // MARK: - API behavior

    func testImportAudioFailsForMissingFile() throws {
        try awaitSync {
            let engine = MockEngine(scenario: .perfect, seed: 1)
            do {
                _ = try await engine.importAudio(url: URL(fileURLWithPath: "/nonexistent/audio.mp3"))
                XCTFail("expected importFailed")
            } catch let error as EngineError {
                guard case .importFailed = error else { XCTFail("wrong error \(error)"); return }
            }
            return ()
        }
    }

    func testPitchFramesBandFilterAndGrid() throws {
        try awaitSync {
            let engine = MockEngine(scenario: .perfect, seed: 1)
            let audio = DecodedAudio(url: URL(fileURLWithPath: "/dev/null"), sampleRate: 44100, channels: 1, duration_s: 12.0)
            // Band excluding the mock's bass range (~87–131 Hz): everything unvoiced.
            let stream = try await engine.pitchFrames(audio, fmin: 500, fmax: 2000)
            var count = 0
            for try await frame in stream {
                XCTAssertEqual(frame.hz, 0.0, "band-filtered frame must be unvoiced at t=\(frame.t)")
                count += 1
            }
            XCTAssertEqual(count, 750) // 12 s / 16 ms
            return ()
        }
    }

    func testPitchFramesThrowsOnInvertedBand() throws {
        try awaitSync {
            let engine = MockEngine(scenario: .perfect, seed: 1)
            let audio = DecodedAudio(url: URL(fileURLWithPath: "/dev/null"), sampleRate: 44100, channels: 1, duration_s: 12.0)
            do {
                _ = try await engine.pitchFrames(audio, fmin: 2000, fmax: 500)
                XCTFail("expected contractViolation")
            } catch let error as EngineError {
                guard case .contractViolation = error else { XCTFail("wrong error \(error)"); return }
            }
            return ()
        }
    }

    func testLivePitchMatchesAnalysisGrid() throws {
        let engine = MockEngine(scenario: .perfect, seed: 1)
        let reference = engine.unfilteredFrames(for: .bass)
        // Simulate a 20 ms @ 16 kHz mic chunk at capture t=4.008 s (mid-note).
        let chunk = MicChunk(samples: [Float](repeating: 0, count: 320), sampleRate: 16000, captureTime_s: 4.008)
        let live = engine.livePitch(chunk)
        let idx = Int(4.008 / 0.016)
        XCTAssertEqual(live, reference[idx])
        // Wall-clock-style capture times wrap into the song timeline.
        let wrapped = engine.livePitch(MicChunk(samples: [], sampleRate: 16000, captureTime_s: 16.008))
        XCTAssertEqual(wrapped, reference[idx])
    }

    func testNoteTrackForUnknownPartThrows() throws {
        try awaitSync {
            let engine = MockEngine(scenario: .perfect, seed: 1)
            do {
                _ = try await engine.noteTrack(.mix(URL(fileURLWithPath: "/dev/null")), part: .soprano)
                XCTFail("expected separationFailed for part absent from mock song")
            } catch let error as EngineError {
                guard case .separationFailed = error else { XCTFail("wrong error \(error)"); return }
            }
            return ()
        }
    }

    func testMakeBundleRefusesForeignDirectory() throws {
        let dir = tempDir("foreign")
        defer { try? FileManager.default.removeItem(at: dir) }
        let foreign = SongManifest(
            engineVersion: "other", id: "01JDIFFERENTDIFFERENTDIFFERENT", title: "Other",
            sourceHash: SourceHash(hex: String(repeating: "a", count: 64)),
            duration_s: 1.0, sampleRate: 44100, hasInstrumental: false,
            parts: [], confidenceSummary: ConfidenceSummary(meanNoteConfidence: 0))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try MockEngine.jsonData(foreign).write(to: dir.appendingPathComponent("song.json"))

        let engine = MockEngine(scenario: .perfect, seed: 1)
        do {
            _ = try engine.makeBundle(to: dir)
            XCTFail("expected refusal to replace foreign bundle")
        } catch let error as EngineError {
            guard case .importFailed = error else { XCTFail("wrong error \(error)"); return }
        }
    }

    func testLivePitchFeedbackBudget() {
        // §8: <100 ms feedback budget — a mock index lookup is microseconds, but
        // guard the contract anyway (catches accidental regression to O(duration)).
        let engine = MockEngine(scenario: .perfect, seed: 1)
        _ = engine.livePitch(MicChunk(samples: [], sampleRate: 16000, captureTime_s: 0)) // warm cache
        let start = Date()
        for i in 0..<1000 {
            _ = engine.livePitch(MicChunk(samples: [], sampleRate: 16000, captureTime_s: Double(i) * 0.01))
        }
        let elapsed_ms = Date().timeIntervalSince(start) * 1000
        XCTAssertLessThan(elapsed_ms / 1000, 1.0, "per-call livePitch must stay far under 100 ms")
    }
}
