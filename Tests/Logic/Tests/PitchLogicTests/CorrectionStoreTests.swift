import XCTest
import EngineCore
@testable import PitchLogic

// J-302 — the correction store, rewritten for CONTRACTS v1.1 · C-11.
//
// WHERE THE FILES LIVE (C-11): INSIDE the song's bundle directory —
//
//     <bundle>/corrections/<PART>.json    one file per corrected part
//     <bundle>/corrections/song.json      the renames + range overrides
//                                          (X-216 proposal — Leto rules)
//
// THE RULES:
//
//   · a saved overlay is there after a "relaunch" (a fresh store over the
//     same bundle directory reads it back);
//   · the ENGINE's tracks are never touched — `notes/<PART>.json` survives
//     every operation the store performs;
//   · a corrupt file is QUARANTINED and reported, never silently read as
//     "no corrections" and never crashed on;
//   · a file written by a newer schema is refused, not downgraded.

final class CorrectionStoreTests: XCTestCase {

    private var bundle: URL!
    private var store: CorrectionStore!

    override func setUpWithError() throws {
        bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("correctionstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        store = CorrectionStore(bundleDirectory: bundle)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: bundle)
    }

    /// A sample per-part overlay (one reassign) + a sample calibration.
    private func sampleOverlay(part: Part = .t1) -> PartCorrectionOverlay {
        PartCorrectionOverlay(part: part, operations: [
            .reassign(fromPart: part, noteIndex: 0, toPart: .bass),
        ])
    }

    private func sampleCalibration() -> SongCalibrationOverlay {
        var calibration = SongCalibrationOverlay()
        calibration.partRenames[Part.t1.rawValue] = "Tenor One"
        calibration.rangeOverrides[Part.bass.rawValue] = .custom(for: .bass, midiLow: 43,
                                                                 midiHigh: 60)
        return calibration
    }

    // MARK: - The paths (C-11's layout)

    func testTheOverlayLivesInsideTheBundleDirectory() {
        XCTAssertEqual(store.correctionsDirectory.path,
                       bundle.appendingPathComponent("corrections").path)
        XCTAssertEqual(store.overlayURL(for: .t2).lastPathComponent, "T2.json")
        XCTAssertEqual(store.songOverlayURL().lastPathComponent, "song.json")
        XCTAssertEqual(store.corruptURL(for: .t2).lastPathComponent, "T2.json.corrupt")
    }

    func testEachPartHasItsOwnFile() throws {
        try store.save(sampleOverlay(part: .t1))
        try store.save(sampleOverlay(part: .t2))

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.overlayURL(for: .t1).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.overlayURL(for: .t2).path))

        // The files are the CONTRACT's shape, keyed by their own part.
        let t1 = try JSONDecoder().decode(PartCorrectionOverlay.self,
                                          from: Data(contentsOf: store.overlayURL(for: .t1)))
        XCTAssertEqual(t1.part, .t1)
        let t2 = try JSONDecoder().decode(PartCorrectionOverlay.self,
                                          from: Data(contentsOf: store.overlayURL(for: .t2)))
        XCTAssertEqual(t2.part, .t2)
    }

    func testTheCalibrationLandsBesideThePartFiles() throws {
        try store.save(sampleOverlay(part: .t1))
        try store.save(calibration: sampleCalibration())

        let url = store.songOverlayURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let decoded = try JSONDecoder().decode(SongCalibrationOverlay.self,
                                               from: Data(contentsOf: url))
        XCTAssertEqual(decoded.displayName(for: .t1), "Tenor One")
        XCTAssertEqual(decoded.rangeOverride(for: .bass)?.midiLow, 43)
    }

    // MARK: - Persistence

    func testCorrectionsSurviveARelaunch() throws {
        let overlay = sampleOverlay(part: .t1)
        try store.save(overlay)

        // A "relaunch": a brand-new store over the same bundle directory.
        let relaunched = CorrectionStore(bundleDirectory: bundle)
        let result = relaunched.loadResult()

        guard case let .loaded(read) = result else {
            return XCTFail("expected the overlay to load, got \(result)")
        }
        XCTAssertEqual(read.partOverlays[.t1], overlay)
        XCTAssertEqual(read.correctionCount, 1)
        XCTAssertTrue(read.problems.isEmpty)
    }

    func testTheCalibrationSurvivesARelaunch() throws {
        let calibration = sampleCalibration()
        try store.save(calibration: calibration)

        let relaunched = CorrectionStore(bundleDirectory: bundle)
        guard case let .loaded(read) = relaunched.loadResult() else {
            return XCTFail("expected the calibration to load")
        }
        XCTAssertEqual(read.calibration, calibration)
    }

    func testAnAbsentOverlayIsAbsentNotCorrupt() {
        XCTAssertEqual(store.loadResult(), .absent)
        XCTAssertTrue(store.load().isEmpty)
    }

    func testTheAbsenceRuleLeavesTheEngineOutputExactly() throws {
        // No `corrections/` directory ⇒ the behaviour is EXACTLY as before:
        // the resolver returns the raw tracks.
        let raw: [Part: NoteTrack] = [
            .t1: NoteTrack(part: .t1, notes: [
                Note(start_s: 0, end_s: 1, midi: 60, confidence: 0.9),
            ]),
        ]
        let result = CorrectionResolver.resolve(raw: raw, overlays: [:])
        XCTAssertEqual(result.tracks[.t1], raw[.t1])
        XCTAssertFalse(result.hasCorrections)
    }

    func testSavingIsAtomicAndLeavesNoTemporaryFiles() throws {
        try store.save(sampleOverlay(part: .t1))
        let children = try FileManager.default.contentsOfDirectory(atPath: store.correctionsDirectory.path)
        XCTAssertEqual(children.filter { $0.contains(".tmp") }, [])
        XCTAssertTrue(children.contains("T1.json"))
    }

    // MARK: - Reversibility

    func testClearingAPartRemovesOnlyThatFile() throws {
        try store.save(sampleOverlay(part: .t1))
        try store.save(sampleOverlay(part: .t2))

        try store.clear(part: .t1)

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.overlayURL(for: .t1).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.overlayURL(for: .t2).path))
    }

    func testClearingAnAbsentOverlayIsHarmless() {
        XCTAssertNoThrow(try store.clear(part: .t1))
    }

    func testClearingTheCalibrationRemovesOnlySongJSON() throws {
        try store.save(sampleOverlay(part: .t1))
        try store.save(calibration: sampleCalibration())

        try store.clearCalibration()

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.songOverlayURL().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.overlayURL(for: .t1).path))
    }

    func testClearAllRemovesTheOverlayFilesAndLeavesTheEngineTracksAlone() throws {
        // The engine's own note file — it must survive everything.
        let notesDir = bundle.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        let engineNotes = notesDir.appendingPathComponent("T1.json")
        let engineBytes = Data("{\"contractVersion\":\"v0.0\",\"part\":\"T1\",\"notes\":[]}".utf8)
        try engineBytes.write(to: engineNotes)

        try store.save(sampleOverlay(part: .t1))
        try store.save(sampleOverlay(part: .t2))
        try store.save(calibration: sampleCalibration())

        try store.clearAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.overlayURL(for: .t1).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.overlayURL(for: .t2).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.songOverlayURL().path))
        // The engine's track is untouched — the overlay is reversible.
        let engineBytesAfter = try Data(contentsOf: engineNotes)
        XCTAssertEqual(engineBytesAfter, engineBytes)
    }

    // MARK: - The corrupt-file rules

    func testACorruptFileIsQuarantinedAndReportedNotCrashed() throws {
        let url = store.overlayURL(for: .t1)
        try FileManager.default.createDirectory(at: store.correctionsDirectory,
                                                withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: url)

        let result = store.loadResult()

        guard case let .loaded(read) = result else {
            return XCTFail("expected a loaded result with problems, got \(result)")
        }
        XCTAssertFalse(read.problems.isEmpty, "the reason must be shown to the user")
        XCTAssertTrue(read.partOverlays.isEmpty)
        // The bad file is kept aside — the user's data is never destroyed.
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.corruptURL(for: .t1).path))
        // And the app does not crash on it.
        XCTAssertTrue(store.load().isEmpty)
    }

    func testACorruptFileIsNeverOverwrittenByALoad() throws {
        let url = store.overlayURL(for: .t1)
        try FileManager.default.createDirectory(at: store.correctionsDirectory,
                                                withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: url)

        _ = store.load()

        // The original file is still there until the user saves something new.
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, "{ this is not json")
    }

    func testAFileWhosePartDoesNotMatchItsNameIsRefusedAndReported() throws {
        // `T1.json` that says it is for T2 — the mismatch is REFUSED, never
        // silently applied to the wrong part.
        let url = store.overlayURL(for: .t1)
        try FileManager.default.createDirectory(at: store.correctionsDirectory,
                                                withIntermediateDirectories: true)
        let json = """
        {"contractVersion":"v1.1","part":"T2","engineVersion":"corrections-0.1.0",
         "operations":[{"op":"delete","fromPart":"T2","noteIndex":0}]}
        """
        try Data(json.utf8).write(to: url)

        let result = store.loadResult()

        guard case let .loaded(read) = result else {
            return XCTFail("expected a loaded result with problems, got \(result)")
        }
        XCTAssertTrue(read.partOverlays.isEmpty, "the mismatched file is refused")
        XCTAssertFalse(read.problems.isEmpty, "and it is REPORTED")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.corruptURL(for: .t1).path),
                      "and it is quarantined")
    }

    func testAnOverlayFromANewerSchemaIsRefusedAndQuarantined() throws {
        let url = store.overlayURL(for: .t1)
        try FileManager.default.createDirectory(at: store.correctionsDirectory,
                                                withIntermediateDirectories: true)
        let json = """
        {"contractVersion":"v2.0","part":"T1","engineVersion":"corrections-9.9.9",
         "operations":[]}
        """
        try Data(json.utf8).write(to: url)

        let result = store.loadResult()

        guard case let .loaded(read) = result else {
            return XCTFail("expected a loaded result with problems, got \(result)")
        }
        XCTAssertTrue(read.partOverlays.isEmpty, "a newer schema is refused, not mis-read")
        XCTAssertFalse(read.problems.isEmpty)
        XCTAssertTrue(read.problems.joined(separator: " ").contains("v2.0"),
                      read.problems.joined(separator: " "))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.corruptURL(for: .t1).path))
    }

    func testSavingAnUnknownSchemaIsRefused() {
        var overlay = sampleOverlay(part: .t1)
        overlay.contractVersion = "v2.0"
        XCTAssertThrowsError(try store.save(overlay)) { error in
            XCTAssertEqual(error as? CorrectionStoreError,
                           .unknownContractVersion(found: "v2.0",
                                                   supported: PartCorrectionOverlay.contractVersion))
        }
    }

    func testSavingACalibrationWithAnUnknownSchemaIsRefused() {
        var calibration = sampleCalibration()
        calibration.contractVersion = "v2.0"
        XCTAssertThrowsError(try store.save(calibration: calibration)) { error in
            XCTAssertEqual(error as? CorrectionStoreError,
                           .unknownContractVersion(found: "v2.0",
                                                   supported: PartCorrectionOverlay.contractVersion))
        }
    }

    func testAFileForAnUnknownPartIsReportedAndQuarantined() throws {
        let url = store.correctionsDirectory.appendingPathComponent("XYZ.json")
        try FileManager.default.createDirectory(at: store.correctionsDirectory,
                                                withIntermediateDirectories: true)
        try Data("{\"contractVersion\":\"v1.1\",\"part\":\"T1\",\"operations\":[]}".utf8).write(to: url)

        let result = store.loadResult()

        guard case let .loaded(read) = result else {
            return XCTFail("expected a loaded result with problems, got \(result)")
        }
        XCTAssertFalse(read.problems.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.correctionsDirectory.appendingPathComponent("XYZ.json.corrupt").path))
    }
}
