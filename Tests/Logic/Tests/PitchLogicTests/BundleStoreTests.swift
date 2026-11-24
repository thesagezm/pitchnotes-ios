import XCTest
import EngineCore
@testable import PitchLogic

// BundleStore tests — J-202 AC "JSON index persists and survives relaunch"
// exercised at the logic layer (every instance method is pure Foundation file
// I/O over a temp root), plus the C-2.2 consumer rule (song.json = complete;
// *.tmp ignored) and clean delete.

final class BundleStoreTests: XCTestCase {

    private var root: URL!
    private var store: BundleStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundlestore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = BundleStore(directory: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeManifest(_ manifest: SongManifest, to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: dir.appendingPathComponent("song.json"))
    }

    private func makeManifest(id: String, title: String) -> SongManifest {
        SongManifest(
            engineVersion: "mock-test",
            id: id,
            title: title,
            sourceHash: SourceHash(hex: String(repeating: "a", count: 64)),
            duration_s: 42.0,
            hasInstrumental: false,
            parts: [],
            confidenceSummary: ConfidenceSummary(meanNoteConfidence: 0.0))
    }

    private func materializeBundle(id: String, title: String, at date: Date = Date()) throws -> BundleRecord {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeManifest(makeManifest(id: id, title: title), to: dir)
        let record = BundleRecord(id: id, title: title, sourceFileName: "song.flac",
                                  sourceBookmark: nil, addedAt: date, duration_s: 42.0)
        try store.register(record)
        return record
    }

    // MARK: Index persistence (D-4 v0)

    func testRegisterThenLoadAcrossFreshStoreRelaunch() throws {
        let older = Date(timeIntervalSinceNow: -100)
        _ = try materializeBundle(id: "01JAAAAAAAAAAAAAAAAAAAAAAA", title: "First", at: older)
        _ = try materializeBundle(id: "01JBBBBBBBBBBBBBBBBBBBBBB", title: "Second")

        // "Relaunch": a brand-new store over the same directory.
        let reopened = BundleStore(directory: root)
        let records = reopened.loadIndex()
        XCTAssertEqual(records.map(\.title), ["Second", "First"], "newest first, persisted")
    }

    func testRegisterDeduplicatesByID() throws {
        _ = try materializeBundle(id: "01JCCCCCCCCCCCCCCCCCCCCCC", title: "Old title")
        try store.register(BundleRecord(id: "01JCCCCCCCCCCCCCCCCCCCCCC", title: "New title",
                                        sourceFileName: "x.flac", sourceBookmark: nil,
                                        addedAt: Date(), duration_s: 42))
        let records = store.loadIndex()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.title, "New title")
    }

    func testCorruptIndexIsQuarantinedAndReturnsEmpty() throws {
        _ = try materializeBundle(id: "01JDDDDDDDDDDDDDDDDDDDDDDD", title: "Will corrupt")
        try "{ not json".data(using: .utf8)!.write(to: store.indexURL)

        let records = store.loadIndex()
        XCTAssertTrue(records.isEmpty, "corrupt index reads as empty; scan rebuilds from disk")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("index.corrupt").path),
            "corrupt file preserved — nothing silently destroyed")
    }

    // MARK: C-2.2 consumer rule

    func testScanIgnoresTmpStagingDirectories() throws {
        _ = try materializeBundle(id: "01JEEEEEEEEEEEEEEEEEEEEEE", title: "Real")

        let staging = store.stagingDirectory(forID: "01JFFFFFFFFFFFFFFFFFF")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try writeManifest(makeManifest(id: "01JFFFFFFFFFFFFFFFFFF", title: "Half-written"), to: staging)

        let scanned = store.scan()
        XCTAssertEqual(scanned.map(\.id), ["01JEEEEEEEEEEEEEEEEEEEEEE"],
                       "a cancelled import's *.tmp staging dir must never surface")
    }

    func testScanDropsRecordsWhoseBundleVanished() throws {
        _ = try materializeBundle(id: "01JGGGGGGGGGGGGGGGGGGGGGGG", title: "Will vanish")
        try FileManager.default.removeItem(at: root.appendingPathComponent("01JGGGGGGGGGGGGGGGGGGGGGGG"))
        XCTAssertTrue(store.scan().isEmpty)
        try store.reconcile()
        XCTAssertTrue(store.loadIndex().isEmpty, "reconcile persists the pruning")
    }

    func testScanAdoptsDiskBundleMissingFromIndex() throws {
        // Crash between bundle rename and index write: disk truth wins.
        let id = "01JHHHHHHHHHHHHHHHHHHHHHHH"
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeManifest(makeManifest(id: id, title: "Adopted"), to: dir)

        let scanned = store.scan()
        XCTAssertEqual(scanned.map(\.id), [id])
        XCTAssertEqual(scanned.first?.title, "Adopted")
    }

    func testIncompleteBundleWithoutSongJSONIsNotAdopted() throws {
        let id = "01JIIIIIIIIIIIIIIIIIIIIIII"
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("stems", isDirectory: true), withIntermediateDirectories: true)
        try "stems but no manifest".data(using: .utf8)!.write(to: dir.appendingPathComponent("stems/VOCALS.wav"))

        XCTAssertTrue(store.isCompleteBundle(at: dir) == false)
        XCTAssertTrue(store.scan().isEmpty)
    }

    // MARK: Delete + staging cleanup + size

    func testDeleteRemovesDirectoryAndIndexEntry() throws {
        _ = try materializeBundle(id: "01JJJJJJJJJJJJJJJJJJJJJJJ", title: "Doomed")
        try store.delete(id: "01JJJJJJJJJJJJJJJJJJJJJJJ")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("01JJJJJJJJJJJJJJJJJJJJJJJ").path))
        XCTAssertTrue(store.loadIndex().isEmpty)
    }

    func testDeleteUnknownIDThrows() {
        XCTAssertThrowsError(try store.delete(id: "01JKKKKKKKKKKKKKKKKKKKKKK")) { error in
            XCTAssertEqual(error as? BundleStoreError, .bundleNotFound("01JKKKKKKKKKKKKKKKKKKKKKK"))
        }
    }

    func testClearStrayStagingDirectories() throws {
        _ = try materializeBundle(id: "01JLLLLLLLLLLLLLLLLLLLLLLL", title: "Keep")
        for id in ["a", "b"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("\(id).tmp", isDirectory: true),
                withIntermediateDirectories: true)
        }
        XCTAssertEqual(store.strayStagingDirectoryCount(), 2, "count before cleanup (Settings row)")
        XCTAssertEqual(store.clearStrayStagingDirectories(), 2)
        XCTAssertEqual(store.clearStrayStagingDirectories(), 0, "idempotent")
        XCTAssertEqual(store.strayStagingDirectoryCount(), 0)
        XCTAssertEqual(store.scan().map(\.id), ["01JLLLLLLLLLLLLLLLLLLLLLLL"], "real bundle untouched")
    }

    func testTotalBytesOnDiskCountsFiles() throws {
        _ = try materializeBundle(id: "01JMMMMMMMMMMMMMMMMMMMMMMM", title: "Sized")
        let manifestBytes = Int64(try Data(contentsOf: root
            .appendingPathComponent("01JMMMMMMMMMMMMMMMMMMMMMMM/song.json")).count)
        let indexBytes = Int64(try Data(contentsOf: store.indexURL).count)
        XCTAssertGreaterThanOrEqual(store.totalBytesOnDisk(), manifestBytes + indexBytes)
    }

    // MARK: J-202 per-song storage (bytesOnDisk(forID:))

    func testBytesOnDiskSumsExactlyTheBundleFiles() throws {
        let id = "01JNNNNNNNNNNNNNNNNNNNNNNN"
        _ = try materializeBundle(id: id, title: "Per-song")
        let dir = root.appendingPathComponent(id, isDirectory: true)
        // Known-size files inside the bundle (stem + notes shapes). Data.write
        // does not create intermediate dirs — make them first.
        for sub in ["stems", "notes"] {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true)
        }
        let stem = Data(repeating: 0x2A, count: 4096)
        let notes = Data(repeating: 0x7B, count: 250)
        try stem.write(to: dir.appendingPathComponent("stems/VOCALS.m4a"))
        try notes.write(to: dir.appendingPathComponent("notes/VOCALS.json"))

        let manifestBytes = Int64(try Data(contentsOf: dir.appendingPathComponent("song.json")).count)
        XCTAssertEqual(store.bytesOnDisk(forID: id), manifestBytes + 4096 + 250,
                       "per-song size = manifest + every regular file in the bundle dir")
        XCTAssertLessThanOrEqual(store.bytesOnDisk(forID: id), store.totalBytesOnDisk(),
                                 "per-song size folds into the root total (index + other bundles)")
    }

    func testBytesOnDiskUnknownBundleIsZero() {
        XCTAssertEqual(store.bytesOnDisk(forID: "01JOOOOOOOOOOOOOOOOOOOOOOO"), 0,
                       "missing bundle → 0 (scan prunes such records anyway)")
    }

    func testDeleteFreesPerSongBytes() throws {
        let id = "01JPPPPPPPPPPPPPPPPPPPPPPP"
        _ = try materializeBundle(id: id, title: "Freed")
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("stems", isDirectory: true), withIntermediateDirectories: true)
        try Data(repeating: 0x2A, count: 1024).write(to: dir.appendingPathComponent("stems/VOCALS.m4a"))

        let before = store.bytesOnDisk(forID: id)
        XCTAssertGreaterThan(before, 0)

        try store.delete(id: id)
        XCTAssertEqual(store.bytesOnDisk(forID: id), 0, "delete frees the bundle's bytes")
        XCTAssertFalse(store.scan().contains { $0.id == id }, "record gone from disk truth")
    }
}
