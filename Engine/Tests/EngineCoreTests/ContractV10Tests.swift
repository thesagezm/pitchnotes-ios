import XCTest
@testable import EngineCore

/// CONTRACTS v1.0 (FROZEN 2026-11-22, L-203): V14/V15 manifest rules, v0.x
/// back-compat, unknown-major rejection, v1.0 JSON round-trip (absent notesFile),
/// and C-8 progress/cancellation (emitter monotonicity, MockEngine staged
/// progress, cancel-leaves-no-bundle semantics).
final class ContractV10Tests: XCTestCase {

    // MARK: - Fixtures

    /// Valid v1.0 manifest in the M2 two-stem shape (C-2.1 example): VOCALS mono
    /// + INSTRUMENTAL stereo, no notes files, top-level v1.0 required fields.
    private func twoStemManifest(hasInstrumental: Bool = true, tuning: Int? = 32,
                                 channels: Int? = 2, version: String = "v1.0") -> SongManifest {
        var parts = [PartInfo(part: .vocals, stemFile: "stems/VOCALS.m4a", channels: 1,
                              notesFile: nil, pitchFile: nil, noteConfidence: 0.0)]
        if hasInstrumental {
            parts.append(PartInfo(part: .instrumental, stemFile: "stems/INSTRUMENTAL.m4a",
                                  channels: 2, notesFile: nil, pitchFile: nil, noteConfidence: 0.0))
        }
        return SongManifest(
            contractVersion: version,
            engineVersion: "engine-0.1.0",
            id: "01JVV10TESTTESTTESTTESTTS",
            title: "Just As I Am",
            sourceHash: SourceHash(hex: String(repeating: "0123456789abcdef", count: 4)),
            duration_s: 213.4,
            sampleRate: 44100,
            channels: channels,
            tuning_cents: tuning,
            hasInstrumental: hasInstrumental,
            parts: parts,
            confidenceSummary: ConfidenceSummary(meanNoteConfidence: 0.0))
    }

    // MARK: - V14 (era-scoped: v1.x required fields)

    func testV14ValidTwoStemManifestIsValid() {
        XCTAssertTrue(BundleValidator.validate(manifest: twoStemManifest()).isValid)
    }

    func testV14MissingChannelsRejected() {
        var m = twoStemManifest()
        m.channels = nil
        let result = BundleValidator.validate(manifest: m)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.violations.contains { $0.rule == "V14" && $0.message.contains("channels") })
    }

    func testV14ChannelRangeRejected() {
        for bad in [0, 3, -1] {
            let m = twoStemManifest(channels: bad)
            let result = BundleValidator.validate(manifest: m)
            XCTAssertFalse(result.isValid, "channels=\(bad) must violate V14")
            XCTAssertTrue(result.violations.contains { $0.rule == "V14" && $0.message.contains("channels") })
        }
    }

    func testV14MissingTuningRejected() {
        var m = twoStemManifest()
        m.tuning_cents = nil
        let result = BundleValidator.validate(manifest: m)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.violations.contains { $0.rule == "V14" && $0.message.contains("tuning_cents") })
    }

    func testV14TuningRangeRejected() {
        for bad in [-51, 51, 500] {
            let m = twoStemManifest(tuning: bad)
            XCTAssertFalse(BundleValidator.validate(manifest: m).isValid, "tuning=\(bad) must violate V14")
        }
        // Boundary values are valid.
        XCTAssertTrue(BundleValidator.validate(manifest: twoStemManifest(tuning: -50)).isValid)
        XCTAssertTrue(BundleValidator.validate(manifest: twoStemManifest(tuning: 50)).isValid)
    }

    // MARK: - V15 (era-scoped: INSTRUMENTAL ⇔ hasInstrumental, D-9)

    func testV15ConsistentPairsValid() {
        // INSTRUMENTAL part + flag true: valid.
        XCTAssertTrue(BundleValidator.validate(manifest: twoStemManifest(hasInstrumental: true)).isValid)
        // Acapella (D-9): no INSTRUMENTAL entry + flag false: valid.
        XCTAssertTrue(BundleValidator.validate(manifest: twoStemManifest(hasInstrumental: false)).isValid)
    }

    func testV15PartWithoutFlagRejected() {
        // Flag false but an INSTRUMENTAL entry still present — V15 fires.
        var m = twoStemManifest(hasInstrumental: false)
        m.parts.append(PartInfo(part: .instrumental, stemFile: "stems/INSTRUMENTAL.m4a",
                                channels: 2, notesFile: nil, pitchFile: nil, noteConfidence: 0.0))
        let result = BundleValidator.validate(manifest: m)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.violations.contains { $0.rule == "V15" })
    }

    func testV15FlagWithoutPartRejected() {
        var m2 = twoStemManifest(hasInstrumental: true)
        m2.parts.removeAll { $0.part == .instrumental } // flag stays true — V15 fires
        let result = BundleValidator.validate(manifest: m2)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.violations.contains { $0.rule == "V15" })
        // D-8 corollary: a VOCALS stem is mono — V3 policy already covers it, but
        // assert explicitly for the M2 shape.
        let mono = twoStemManifest()
        XCTAssertTrue(mono.parts.allSatisfy { $0.part == .instrumental ? $0.channels == 2 : $0.channels == 1 })
    }

    // MARK: - Back-compat (C-2.2: v0.x manifests remain valid under V1–V13 ONLY)

    func testV0ManifestWithoutV14FieldsStaysValid() {
        // v0.0-era manifest with NO channels/tuning_cents: valid under its era.
        let m = twoStemManifest(tuning: nil, channels: nil, version: "v0.0")
        // Strip the INSTRUMENTAL part so v0.x parts[] mirror the old mock shape.
        var old = m
        old.parts = [PartInfo(part: .bass, stemFile: "stems/BASS.m4a", channels: 1,
                              notesFile: "notes/BASS.json", pitchFile: nil, noteConfidence: 0.9)]
        old.hasInstrumental = false
        XCTAssertTrue(BundleValidator.validate(manifest: old).isValid)
    }

    func testV0ManifestWithInconsistentInstrumentalStaysValidUnderEraRules() {
        // V15 is era-scoped v1.x — a v0.x manifest with disagreeing
        // hasInstrumental/parts is NOT invalidated by V15 (back-compat permanent).
        var old = twoStemManifest(hasInstrumental: true, version: "v0.0")
        old.hasInstrumental = false // parts[] still has INSTRUMENTAL — v0.x: no V15
        XCTAssertTrue(BundleValidator.validate(manifest: old).isValid)
    }

    func testUnknownMajorVersionRejected() {
        let m = twoStemManifest(version: "v2.0")
        let result = BundleValidator.validate(manifest: m)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.violations.contains { $0.rule == "V1" && $0.message.contains("known major") })
    }

    func testMalformedVersionRejected() {
        let m = twoStemManifest(version: "banana")
        let result = BundleValidator.validate(manifest: m)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.violations.contains { $0.rule == "V1" })
    }

    // MARK: - v1.0 JSON round-trip (C-2.1 M2 shape: notesFile key ABSENT)

    func testV10JSONRoundTripOmitsAbsentNotesFile() throws {
        let m = twoStemManifest()
        let data = try JSONEncoder().encode(m)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let parts = try XCTUnwrap(json["parts"] as? [[String: Any]])
        // M2 two-stem shape: no notesFile keys at all.
        XCTAssertTrue(parts.allSatisfy { $0["notesFile"] == nil })
        XCTAssertEqual(json["channels"] as? Int, 2)
        XCTAssertEqual(json["tuning_cents"] as? Int, 32)
        XCTAssertEqual(json["contractVersion"] as? String, "v1.0")

        let decoded = try JSONDecoder().decode(SongManifest.self, from: data)
        XCTAssertEqual(decoded, m)
        XCTAssertTrue(decoded.parts.allSatisfy { $0.notesFile == nil })
    }

    func testV0JSONWithNotesFileStillDecodes() throws {
        // v0.x-era JSON: notesFile present, no top-level channels/tuning_cents.
        let json = """
        {
          "contractVersion": "v0.0",
          "engineVersion": "engine-mock-0.0.0",
          "id": "01JOLDTESTOLDTESTOLDTESTOL",
          "title": "Old",
          "sourceHash": { "algo": "blake3", "hex": "0000000000000000000000000000000000000000000000000000000000000000" },
          "duration_s": 12.0,
          "sampleRate": 44100,
          "hasInstrumental": false,
          "parts": [
            { "part": "BASS", "stemFile": "stems/BASS.wav", "channels": 1,
              "notesFile": "notes/BASS.json", "noteConfidence": 0.9 }
          ],
          "confidenceSummary": { "meanNoteConfidence": 0.9 }
        }
        """
        let decoded = try JSONDecoder().decode(SongManifest.self, from: Data(json.utf8))
        XCTAssertNil(decoded.channels)
        XCTAssertNil(decoded.tuning_cents)
        XCTAssertEqual(decoded.parts.first?.notesFile, "notes/BASS.json")
        XCTAssertTrue(BundleValidator.validate(manifest: decoded).isValid)
    }

    // MARK: - C-8 · ImportProgressEmitter monotonicity + clamp

    func testEmitterMonotonicAndClamped() {
        let emitter = ImportProgressEmitter()
        let received = ProgressCollector()
        emitter.setHandler { received.append($0) }

        emitter.emit(ImportProgress(stage: .decoding, fraction: 0.5))
        emitter.emit(ImportProgress(stage: .decoding, fraction: 0.2)) // wobble → held
        emitter.emit(ImportProgress(stage: .separating, fraction: 1.7)) // clamp → 1
        emitter.emit(ImportProgress(stage: .separating, fraction: -3)) // clamp → held 1

        let events = received.snapshot()
        XCTAssertEqual(events.map(\.fraction), [0.5, 0.5, 1.0, 1.0])
        XCTAssertEqual(events.map(\.stage), [.decoding, .decoding, .separating, .separating])
    }

    func testEmitterNewHandlerRestartsMonotonicBase() {
        let emitter = ImportProgressEmitter()
        let first = ProgressCollector()
        emitter.setHandler { first.append($0) }
        emitter.emit(ImportProgress(stage: .decoding, fraction: 0.8))
        let second = ProgressCollector()
        emitter.setHandler { second.append($0) } // last handler wins, base resets
        emitter.emit(ImportProgress(stage: .decoding, fraction: 0.3))
        XCTAssertEqual(first.snapshot().map(\.fraction), [0.8])
        XCTAssertEqual(second.snapshot().map(\.fraction), [0.3])
        emitter.setHandler(nil)
        let third = ProgressCollector()
        emitter.setHandler { third.append($0) } // nil clears; next set restarts
        XCTAssertEqual(third.snapshot().map(\.fraction), [])
    }

    // MARK: - C-8 · MockEngine staged progress + cancellation

    /// Lock-guarded collector — the C-8 handler is `@Sendable` and may run on any
    /// thread (Swift 6: no captured-var mutation in concurrent closures).
    private final class ProgressCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ImportProgress] = []
        func append(_ p: ImportProgress) { lock.lock(); items.append(p); lock.unlock() }
        func snapshot() -> [ImportProgress] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func testMockEngineProgressPerStageMonotonicEndsAtOne() throws {
        let dir = tempDir("progress")
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = MockEngine(scenario: .perfect, seed: 3, bundleDirectory: dir)
        let received = ProgressCollector()
        engine.setImportProgressHandler { received.append($0) }
        _ = try engine.makeBundle()

        let events = received.snapshot()
        for stage in ImportStage.allCases {
            XCTAssertTrue(events.contains { $0.stage == stage }, "no progress for stage \(stage.rawValue)")
        }
        let fractions = events.map(\.fraction)
        XCTAssertEqual(fractions, fractions.sorted(), "fraction must be monotonic (C-8)")
        XCTAssertEqual(fractions.last, 1.0, "1.0 only at completion")
        // Deterministic emission — second run with a fresh handler is identical.
        let again = ProgressCollector()
        engine.setImportProgressHandler { again.append($0) }
        _ = try engine.makeBundle()
        let second = again.snapshot()
        XCTAssertEqual(second.map(\.stage), events.map(\.stage))
        XCTAssertEqual(second.map(\.fraction), events.map(\.fraction))
    }

    func testMockEngineCancelLeavesNoPartialBundle() throws {
        let dir = tempDir("cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = MockEngine(scenario: .perfect, seed: 3, bundleDirectory: dir)
        engine.setImportProgressHandler { _ in }

        let task = Task {
            try await engine.separate(DecodedAudio(url: dir, sampleRate: 44100, channels: 1, duration_s: 12.0),
                                      mode: .twoStem)
        }
        task.cancel()
        do {
            _ = try awaitSyncTask(task)
            XCTFail("expected CancellationError from cancelled Task")
        } catch is CancellationError {
            // expected
        }

        // C-2.2/P-202 AC: no partial bundle, no staging residue.
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("song.json").path))
        let parent = dir.deletingLastPathComponent()
        let residue = try fm.contentsOfDirectory(atPath: parent.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(residue.isEmpty, "staging residue left behind: \(residue)")
    }

    // MARK: - Helpers

    private func tempDir(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("contractv10-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    /// Synchronously awaits a task's result, rethrowing its error (test helper —
    /// the suite runs on Linux XCTest without async test methods elsewhere).
    private func awaitSyncTask<T>(_ task: Task<T, Error>) throws -> T {
        let sema = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task {
            let result: Result<T, Error>
            do { result = .success(try await task.value) }
            catch { result = .failure(error) }
            box.store(result)
            sema.signal()
        }
        sema.wait()
        return try box.load().get()
    }

    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<T, Error>?
        func store(_ r: Result<T, Error>) { lock.lock(); value = r; lock.unlock() }
        func load() -> Result<T, Error> {
            lock.lock(); defer { lock.unlock() }
            guard let v = value else { fatalError("result not stored") }
            return v
        }
    }
}
