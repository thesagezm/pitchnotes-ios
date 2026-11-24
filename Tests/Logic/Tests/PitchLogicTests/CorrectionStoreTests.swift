import XCTest
import EngineCore
@testable import PitchLogic

// J-302 — the correction store: the AC's "corrections persist" and
// "reversible" requirements, exercised over a temp root (the same pure
// Foundation file-I/O pattern as BundleStoreTests).
//
// THE RULES:
//   · a saved overlay is there after a "relaunch" (a fresh store over the
//     same directory reads it back);
//   · clearing it restores the engine's output exactly (the raw tracks were
//     never touched — that lives in CorrectionOverlayTests);
//   · a corrupt file is QUARANTINED and reported, never silently read as
//     "no corrections" and never crashed on;
//   · a file written by a newer schema is refused, not downgraded.

final class CorrectionStoreTests: XCTestCase {

    private var root: URL!
    private var store: CorrectionStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("correctionstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = CorrectionStore(directory: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func sampleOverlay(bundleID: String = "01JABC") -> CorrectionOverlay {
        var overlay = CorrectionOverlay.empty(bundleID: bundleID)
        overlay.append(.move(NoteKey(part: .t1, note: Note(start_s: 1.0, end_s: 1.5, midi: 60, confidence: 0.9)),
                             toPart: .bass))
        overlay.rename(part: .t1, to: "Tenor One")
        overlay.setRange(.custom(midiLow: 43, midiHigh: 60), for: .bass)
        return overlay
    }

    // MARK: - Persistence

    func testCorrectionsSurviveARelaunch() throws {
        let overlay = sampleOverlay()
        try store.save(overlay)

        // A "relaunch": a brand-new store over the same directory.
        let relaunched = CorrectionStore(directory: root)
        let result = relaunched.loadResult(forBundleID: "01JABC")

        guard case let .loaded(read) = result else {
            return XCTFail("expected the overlay to load, got \(result)")
        }
        XCTAssertEqual(read.ops, overlay.ops)
        XCTAssertEqual(read.partRenames, overlay.partRenames)
        XCTAssertEqual(read.rangeOverrides, overlay.rangeOverrides)
    }

    func testAnAbsentOverlayIsAbsentNotCorrupt() {
        XCTAssertEqual(store.loadResult(forBundleID: "nothing-here"), .absent)
        XCTAssertTrue(store.load(forBundleID: "nothing-here").isEmpty)
    }

    func testSavingIsAtomicAndLeavesNoTemporaryFiles() throws {
        try store.save(sampleOverlay())
        let children = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(children.filter { $0.contains(".tmp") }, [])
        XCTAssertTrue(children.contains("01JABC.json"))
    }

    func testOverlaysAreListedBySong() throws {
        try store.save(sampleOverlay(bundleID: "01JABC"))
        try store.save(sampleOverlay(bundleID: "01JDEF"))
        XCTAssertEqual(store.bundleIDsWithOverlays(), ["01JABC", "01JDEF"])
    }

    // MARK: - Reversibility

    func testClearingRemovesTheOverlay() throws {
        try store.save(sampleOverlay())
        try store.clear(forBundleID: "01JABC")
        XCTAssertEqual(store.loadResult(forBundleID: "01JABC"), .absent)
    }

    func testClearingAnAbsentOverlayIsHarmless() {
        XCTAssertNoThrow(try store.clear(forBundleID: "nothing-here"))
    }

    // MARK: - The corrupt-file rules

    func testACorruptFileIsQuarantinedAndReportedNotCrashed() throws {
        let url = store.overlayURL(forBundleID: "01JABC")
        try Data("{ this is not json".utf8).write(to: url)

        let result = store.loadResult(forBundleID: "01JABC")

        guard case let .corrupted(reason) = result else {
            return XCTFail("expected a corrupt result, got \(result)")
        }
        XCTAssertFalse(reason.isEmpty, "the reason must be shown to the user")
        // The bad file is kept aside — the user's data is never destroyed.
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.corruptURL(forBundleID: "01JABC").path))
        // And the app does not crash on it.
        XCTAssertTrue(store.load(forBundleID: "01JABC").isEmpty)
    }

    func testACorruptFileIsNeverOverwrittenByALoad() throws {
        let url = store.overlayURL(forBundleID: "01JABC")
        try Data("{ this is not json".utf8).write(to: url)

        _ = store.load(forBundleID: "01JABC")

        // The original file is still there until the user saves something new.
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, "{ this is not json")
    }

    func testAnOverlayFromANewerSchemaIsRefused() throws {
        let url = store.overlayURL(forBundleID: "01JABC")
        let json = """
        {"version":999,"bundleID":"01JABC","updatedAt":0,"partRenames":{},"rangeOverrides":{},"ops":[]}
        """
        try Data(json.utf8).write(to: url)

        let result = store.loadResult(forBundleID: "01JABC")

        guard case let .corrupted(reason) = result else {
            return XCTFail("expected a corrupt result for an unknown schema, got \(result)")
        }
        XCTAssertTrue(reason.contains("999"), reason)
    }

    func testSavingAnUnknownSchemaIsRefused() {
        var overlay = sampleOverlay()
        overlay.version = 999
        XCTAssertThrowsError(try store.save(overlay)) { error in
            XCTAssertEqual(error as? CorrectionStoreError,
                           .unknownVersion(found: 999, supported: CorrectionOverlay.currentVersion))
        }
    }

    // MARK: - The default location

    func testTheDefaultStoreLivesInApplicationSupport() throws {
        let store = try CorrectionStore.makeDefault()
        XCTAssertTrue(store.root.path.contains("PitchNotes"))
        XCTAssertTrue(store.root.lastPathComponent == "Corrections")
    }
}
