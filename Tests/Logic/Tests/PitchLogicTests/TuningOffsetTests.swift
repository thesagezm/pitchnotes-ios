import XCTest
import EngineCore
@testable import PitchLogic

// J-205 / D-22 tuning-reference tests: override resolution math, chip
// display states (+35c/−35c/in-tune), the lane-local v1.0 manifest decoder
// (V14/V15), override persistence in the bundle index, and the ribbon's
// reference-offset injection (note-name + cents reference).

final class TuningOffsetTests: XCTestCase {

    // MARK: - TuningPolicy (override math)

    func testRecordingDefaultUsesDetectedCents() {
        XCTAssertEqual(TuningPolicy.resolvedCents(detected: 32, override: nil), 32)
        XCTAssertEqual(
            TuningPolicy.resolvedCents(detected: 32,
                                       override: TuningOverride(mode: .recording)), 32,
            "explicit .recording == nil default")
    }

    func testForceA440ZeroesTheReference() {
        XCTAssertEqual(
            TuningPolicy.resolvedCents(detected: 32,
                                       override: TuningOverride(mode: .forceA440)), 0,
            "force A440 ignores the estimate entirely")
        XCTAssertEqual(
            TuningPolicy.resolvedCents(detected: -48,
                                       override: TuningOverride(mode: .forceA440)), 0)
    }

    func testManualOverrideClampsToContractRange() {
        XCTAssertEqual(TuningPolicy.resolvedCents(
            detected: 0, override: TuningOverride(mode: .manual, manualCents: 20)), 20)
        XCTAssertEqual(TuningPolicy.resolvedCents(
            detected: 32, override: TuningOverride(mode: .manual, manualCents: -35)), -35,
            "manual wins over detected")
        XCTAssertEqual(TuningPolicy.resolvedCents(
            detected: 0, override: TuningOverride(mode: .manual, manualCents: 90)),
            TuningPolicy.centsRange.upperBound, "clamped to +50 (D-22)")
        XCTAssertEqual(TuningPolicy.resolvedCents(
            detected: 0, override: TuningOverride(mode: .manual, manualCents: -99)),
            TuningPolicy.centsRange.lowerBound, "clamped to −50 (D-22)")
        XCTAssertEqual(TuningPolicy.resolvedCents(
            detected: 0, override: TuningOverride(mode: .manual, manualCents: nil)), 0,
            "manual without a value falls back to 0, not the estimate")
    }

    // MARK: - TuningDisplay (chip states)

    func testChipShowsForSystematicOffsets() {
        XCTAssertTrue(TuningDisplay(resolvedCents: 32).showsChip, "+32c sharp shows")
        XCTAssertTrue(TuningDisplay(resolvedCents: -35).showsChip, "−35c flat shows")
        XCTAssertTrue(TuningDisplay(resolvedCents: 10).showsChip,
                      "≥ estimator MIN_CENTS (10) shows — the estimator reports 0 below it")
        XCTAssertFalse(TuningDisplay(resolvedCents: 0).showsChip, "in-tune hides")
        XCTAssertFalse(TuningDisplay(resolvedCents: 9).showsChip, "sub-threshold hides")
        XCTAssertFalse(TuningDisplay(resolvedCents: -5).showsChip)
    }

    func testDisplayLabelSharpAndFlat() {
        XCTAssertEqual(TuningDisplay(resolvedCents: 32).label,
                       "+32c sharp — reference adjusted")
        XCTAssertEqual(TuningDisplay(resolvedCents: -35).label,
                       "−35c flat — reference adjusted")
        XCTAssertEqual(TuningDisplay(resolvedCents: 0).label, "", "hidden → empty label")
    }

    // MARK: - Manifest → tuning estimate (SWAP SEAM #1: EngineCore consumes)

    private func v1JSON(channels: String = "2", tuning: String = "32",
                        hasInstrumental: String = "true",
                        parts: String,
                        contractVersion: String = "v1.0") -> Data {
        """
        {
          "contractVersion": "\(contractVersion)",
          "engineVersion": "mock-test",
          "id": "01JTTTTTTTTTTTTTTTTTTTTTTT",
          "title": "Tuning probe",
          "sourceHash": { "algo": "blake3", "hex": "\(String(repeating: "a", count: 64))" },
          "duration_s": 30.0,
          "sampleRate": 44100,
          "channels": \(channels),
          "tuning_cents": \(tuning),
          "hasInstrumental": \(hasInstrumental),
          "parts": [\(parts)],
          "confidenceSummary": { "meanNoteConfidence": 0.8 }
        }
        """.data(using: .utf8)!
    }

    /// A v0-era manifest that carries NO estimate (v0.0 had no `tuning_cents`).
    private func v0JSON(parts: String, contractVersion: String = "v0.0") -> Data {
        """
        {
          "contractVersion": "\(contractVersion)",
          "engineVersion": "mock-test",
          "id": "01JTTTTTTTTTTTTTTTTTTTTTTT",
          "title": "Tuning probe",
          "sourceHash": { "algo": "blake3", "hex": "\(String(repeating: "a", count: 64))" },
          "duration_s": 30.0,
          "sampleRate": 44100,
          "hasInstrumental": false,
          "parts": [\(parts)],
          "confidenceSummary": { "meanNoteConfidence": 0.8 }
        }
        """.data(using: .utf8)!
    }

    // Fixtures use T1 (a C-1 rawValue on THIS branch) — the M2 two-stem
    // "VOCALS" rawValue decodes only after Paul's Part.vocals merge; the
    // estimate reader is rawValue-agnostic and needs no change then.
    // notesFile: OPTIONAL per C-2.1 since v1.0 (Paul's EngineCore) and
    // tolerated on v0.x — present keys survive either way.
    private let voicePart = #"""
        { "part": "T1", "stemFile": "stems/T1.m4a", "channels": 1, "notesFile": "notes/T1.json", "noteConfidence": 0.0 }
        """#

    private func manifest(_ data: Data) throws -> SongManifest {
        try JSONDecoder().decode(SongManifest.self, from: data)
    }

    func testValidTuningCentsReadsSharpFlatAndInTune() throws {
        for (cents, name) in [(32, "sharp"), (-35, "flat"), (0, "in-tune")] {
            let m = try manifest(v1JSON(tuning: String(cents),
                                        hasInstrumental: "false",
                                        parts: voicePart))
            XCTAssertEqual(m.validTuningCents, cents, name)
            XCTAssertEqual(m.title, "Tuning probe")
        }
    }

    func testValidTuningCentsIsNilWhenTheEngineFlagsV14() throws {
        // V14 (the ENGINE's rule): a v1.x manifest must carry tuning_cents in
        // [−50,+50]. Missing or out-of-range ⇒ "no estimate" — never a
        // clamped guess (D-12 honesty).
        let missing = try manifest("""
        {
          "contractVersion": "v1.0", "engineVersion": "m", "id": "x", "title": "t",
          "sourceHash": { "algo": "blake3", "hex": "\(String(repeating: "a", count: 64))" },
          "duration_s": 30.0, "sampleRate": 44100, "channels": 1, "hasInstrumental": false,
          "parts": [], "confidenceSummary": { "meanNoteConfidence": 0.0 }
        }
        """.data(using: .utf8)!)
        XCTAssertNil(missing.validTuningCents, "missing tuning_cents → no estimate")
        XCTAssertTrue(BundleValidator.validate(manifest: missing).violations.contains { $0.rule == "V14" },
                      "the ENGINE flags V14 — the app mirrors it, it does not re-decide")

        let outOfRange = try manifest(v1JSON(tuning: "80", parts: voicePart))
        XCTAssertNil(outOfRange.validTuningCents, "tuning_cents 80 → no estimate")
    }

    func testValidTuningCentsIsNilWhenTheEngineFlagsV15() throws {
        // V15: hasInstrumental true but no INSTRUMENTAL entry ⇒ the manifest
        // disagrees with itself ⇒ no estimate.
        let inconsistent = try manifest(v1JSON(parts: voicePart))
        XCTAssertNil(inconsistent.validTuningCents)
        XCTAssertTrue(BundleValidator.validate(manifest: inconsistent).violations.contains { $0.rule == "V15" },
                      "the ENGINE flags V15")
    }

    func testValidTuningCentsIsNilForAV0EraManifestWithoutAnEstimate() throws {
        // `tuning_cents` has been OPTIONAL since v0.1.1 (D-22) — a v0-era
        // manifest that carries one keeps it (the estimate is era-independent;
        // V14/V15 are era-scoped to v1.x and do not fire here). A v0-era
        // manifest WITHOUT one ⇒ no estimate.
        let v0 = try manifest(v0JSON(parts: voicePart))
        XCTAssertNil(v0.validTuningCents)
        XCTAssertTrue(BundleValidator.validate(manifest: v0).violations.allSatisfy { $0.rule != "V14" },
                      "V14 is era-scoped to v1.x — a v0-era manifest is judged by V1–V13")
    }

    func testValidTuningCentsIsNilForUnparseableInput() {
        XCTAssertNil(try? manifest(Data("not json".utf8)))
    }

    // MARK: - Override persistence (bundle index, D-4 v0)

    private var root: URL!
    private var store: BundleStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tuning-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = BundleStore(directory: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func registerSong(id: String) throws {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}".data(using: .utf8)!.write(to: dir.appendingPathComponent("stems-unused.txt"))
        try store.register(BundleRecord(id: id, title: "Song", sourceFileName: "s.flac",
                                        sourceBookmark: nil, addedAt: Date(), duration_s: 30))
    }

    func testOverridePersistsAcrossFreshStore() throws {
        let id = "01JUUUUUUUUUUUUUUUUUUUUUUU"
        try registerSong(id: id)

        try store.setTuningOverride(TuningOverride(mode: .forceA440), forID: id)
        let reopened = BundleStore(directory: root)
        XCTAssertEqual(reopened.tuningOverride(forID: id), TuningOverride(mode: .forceA440),
                       "override survives relaunch (index persistence)")

        try store.setTuningOverride(TuningOverride(mode: .manual, manualCents: -35), forID: id)
        XCTAssertEqual(store.tuningOverride(forID: id),
                       TuningOverride(mode: .manual, manualCents: -35), "updates replace")
    }

    func testClearOverrideReturnsToRecordingDefault() throws {
        let id = "01JVVVVVVVVVVVVVVVVVVVVVVV"
        try registerSong(id: id)
        try store.setTuningOverride(TuningOverride(mode: .manual, manualCents: 20), forID: id)
        try store.setTuningOverride(nil, forID: id)
        XCTAssertNil(store.tuningOverride(forID: id))
        XCTAssertEqual(TuningPolicy.resolvedCents(detected: 32, override: nil), 32,
                       "cleared override = recording default (D-22)")
    }

    func testSetOverrideUnknownIDThrows() {
        XCTAssertThrowsError(try store.setTuningOverride(
            TuningOverride(mode: .forceA440), forID: "01JWWWWWWWWWWWWWWWWWWWWWWW"))
    }

    // MARK: - Ribbon reference-offset injection (D-22: note name + cents ref)

    func testRibbonReadingOffsetMakesFaithfulSingerInTune() {
        // Recording is +35c sharp: a voice reproducing the recording exactly
        // (A4 at 440·2^(35/1200)) reads in-tune at 0¢ with the offset applied,
        // and the note name (nearestMidi) stays A4 on the recording's grid.
        let sharpA4 = 440.0 * pow(2.0, 35.0 / 1200.0)
        let withOffset = RibbonMapper.reading(hz: sharpA4, confidence: 0.9, reference: nil,
                                              tolerance: 50, octaveEquivalence: true,
                                              referenceOffsetCents: 35)
        XCTAssertEqual(withOffset.state, .inTune)
        XCTAssertEqual(withOffset.cents, 0.0, accuracy: 0.001)
        XCTAssertEqual(withOffset.nearestMidi, 69, "note name stays A4 (offset grid)")

        // Control: the same voice WITHOUT the offset reads ~35c sharp.
        let withoutOffset = RibbonMapper.reading(hz: sharpA4, confidence: 0.9, reference: nil,
                                                 tolerance: 50, octaveEquivalence: true)
        XCTAssertEqual(withoutOffset.cents, 35.0, accuracy: 0.001)
    }

    func testRibbonReadingOffsetAppliesToScoreReferenceMode() {
        // −35c flat recording + score reference A4 (440 Hz, the M2 two-stem
        // path's ref mode): the faithful voice sits 0¢ off the ADJUSTED
        // reference — D-22 "grade adds tuning_cents to the reference".
        let flatA4 = 440.0 * pow(2.0, -35.0 / 1200.0)
        let reading = RibbonMapper.reading(hz: flatA4, confidence: 0.9,
                                           reference: RibbonReference(midi: 69),
                                           tolerance: 50, octaveEquivalence: true,
                                           referenceOffsetCents: -35)
        XCTAssertEqual(reading.state, .inTune)
        XCTAssertEqual(reading.cents, 0.0, accuracy: 0.001)

        // Singing the A440 pitch against a −35c-adjusted reference reads flat.
        let againstAdjusted = RibbonMapper.reading(hz: 440.0, confidence: 0.9,
                                                   reference: RibbonReference(midi: 69),
                                                   tolerance: 50, octaveEquivalence: true,
                                                   referenceOffsetCents: -35)
        XCTAssertEqual(againstAdjusted.cents, 35.0, accuracy: 0.001, "sharp vs adjusted ref")
    }

    func testIndexWithoutOverrideFieldDecodesToNil() throws {
        // Pre-J-205 index JSON (no tuningOverride key) must decode unchanged.
        let legacy = """
        { "version": 1, "records": [ { "id": "01JXXXXXXXXXXXXXXXXXXXXXXX",
          "title": "Legacy", "sourceFileName": "a.mp3", "sourceBookmark": null,
          "addedAt": "2026-11-22T10:00:00Z", "duration_s": 30.0 } ] }
        """.data(using: .utf8)!
        try legacy.write(to: store.indexURL)
        let records = store.loadIndex()
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records[0].tuningOverride, "absent optional key → nil (back-compat)")
    }
}
