import Foundation
import XCTest
@testable import EngineCore

// P-204/P-205 · the portable parts of the bundle assembly:
//
//   - the D-9 instrumental-presence heuristic (near-silent instrumental ⇒
//     acapella ⇒ hasInstrumental = false);
//   - the engine-side import cache index (source hash → bundle id).
//
// Both live in EngineCore so they are Linux-testable; the Apple-side ALAC
// writer and the real import engine are proven by the ImportKit macOS tests.

final class BundleAssemblyTests: XCTestCase {

    private func tempDir(_ name: String) -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("p204-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A mono PCM16 stem at a given RMS level (dBFS). `dbfs = nil` ⇒ digital
    /// silence.
    private func writeStem(at url: URL, rmsDBFS: Double?, frames: Int = 44100) throws {
        var samples = [Float](repeating: 0, count: frames)
        if let rmsDBFS {
            let amplitude: Float = Float(pow(10.0, rmsDBFS / 20.0))
            let scale: Float = amplitude * Float(sqrt(2.0))
            for i in 0..<frames {
                // A sine has RMS = amplitude/√2 — scale so the RMS lands on
                // the requested level.
                let phase: Double = 2.0 * Double.pi * 220.0 * Double(i) / 44100.0
                samples[i] = scale * Float(sin(phase))
            }
        }
        try PCMWavWriter.write(url: url, samples: samples, sampleRate: 44100, channels: 1)
    }

    // MARK: - D-9 presence heuristic (P-205)

    func testDigitalSilenceIsNearSilent() throws {
        let dir = tempDir("silence")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stem = dir.appendingPathComponent("instrumental.wav")
        try writeStem(at: stem, rmsDBFS: nil)
        XCTAssertFalse(InstrumentalPresenceHeuristic.measure(instrumentalStem: stem),
                       "a digitally silent instrumental means acapella")
    }

    func testVeryQuietStemIsNearSilent() throws {
        let dir = tempDir("quiet")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stem = dir.appendingPathComponent("instrumental.wav")
        try writeStem(at: stem, rmsDBFS: -70)
        XCTAssertFalse(InstrumentalPresenceHeuristic.measure(instrumentalStem: stem),
                       "−70 dBFS is below the −50 dBFS near-silent threshold")
    }

    func testRealAccompanimentIsPresent() throws {
        let dir = tempDir("loud")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stem = dir.appendingPathComponent("instrumental.wav")
        try writeStem(at: stem, rmsDBFS: -20)
        XCTAssertTrue(InstrumentalPresenceHeuristic.measure(instrumentalStem: stem),
                      "−20 dBFS is a real accompaniment")
    }

    func testThresholdBoundary() throws {
        let dir = tempDir("boundary")
        defer { try? FileManager.default.removeItem(at: dir) }
        let justBelow = dir.appendingPathComponent("below.wav")
        try writeStem(at: justBelow, rmsDBFS: InstrumentalPresenceHeuristic.nearSilentRMSdB - 6)
        XCTAssertFalse(InstrumentalPresenceHeuristic.measure(instrumentalStem: justBelow))

        let justAbove = dir.appendingPathComponent("above.wav")
        try writeStem(at: justAbove, rmsDBFS: InstrumentalPresenceHeuristic.nearSilentRMSdB + 6)
        XCTAssertTrue(InstrumentalPresenceHeuristic.measure(instrumentalStem: justAbove))
    }

    func testMissingStemIsAcapellaAndUnreadableStemKeepsTheAccompaniment() {
        // No instrumental at all ⇒ acapella.
        XCTAssertFalse(InstrumentalPresenceHeuristic.measure(instrumentalStem: nil))
        // Unreadable ⇒ we do NOT delete a stem we failed to measure.
        XCTAssertTrue(InstrumentalPresenceHeuristic.measure(
            instrumentalStem: URL(fileURLWithPath: "/tmp/definitely-not-a-stem-\(UUID().uuidString).wav")))
    }

    func testRMSMeasurementMatchesTheWrittenLevel() throws {
        let dir = tempDir("rms")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stem = dir.appendingPathComponent("instrumental.wav")
        try writeStem(at: stem, rmsDBFS: -30)
        let measured = try XCTUnwrap(InstrumentalPresenceHeuristic.rmsDB(url: stem))
        XCTAssertEqual(measured, -30, accuracy: 1.5)
    }

    // MARK: - Import cache index (P-204)

    func testCacheIndexRecordsAndFindsBySourceHash() {
        let dir = tempDir("cache")
        defer { try? FileManager.default.removeItem(at: dir) }
        let hash = String(repeating: "a", count: 64)

        XCTAssertNil(BundleCacheIndex.lookup(sourceHash: hash, libraryRoot: dir))
        BundleCacheIndex.record(sourceHash: hash, bundleID: "BUNDLE1", title: "Hymn", libraryRoot: dir)
        XCTAssertEqual(BundleCacheIndex.lookup(sourceHash: hash, libraryRoot: dir), "BUNDLE1")

        // A second record for the same hash REPLACES the entry (no duplicates).
        BundleCacheIndex.record(sourceHash: hash, bundleID: "BUNDLE2", title: "Hymn", libraryRoot: dir)
        XCTAssertEqual(BundleCacheIndex.lookup(sourceHash: hash, libraryRoot: dir), "BUNDLE2")
        XCTAssertEqual(BundleCacheIndex.load(libraryRoot: dir).entries.count, 1)
    }

    func testCacheIndexPrunesEntriesWhoseBundleIsGone() {
        let dir = tempDir("prune")
        defer { try? FileManager.default.removeItem(at: dir) }
        let hash = String(repeating: "b", count: 64)
        BundleCacheIndex.record(sourceHash: hash, bundleID: "GONE", title: "Hymn", libraryRoot: dir)
        // No directory named "GONE" exists ⇒ prune drops the entry.
        BundleCacheIndex.prune(libraryRoot: dir)
        XCTAssertNil(BundleCacheIndex.lookup(sourceHash: hash, libraryRoot: dir))

        // With the bundle present, the entry survives.
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("KEPT"),
                                                 withIntermediateDirectories: true)
        BundleCacheIndex.record(sourceHash: hash, bundleID: "KEPT", title: "Hymn", libraryRoot: dir)
        BundleCacheIndex.prune(libraryRoot: dir)
        XCTAssertEqual(BundleCacheIndex.lookup(sourceHash: hash, libraryRoot: dir), "KEPT")
    }

    func testCorruptCacheIndexIsTreatedAsEmpty() {
        let dir = tempDir("corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = BundleCacheIndex.url(inLibraryRoot: dir)
        try? Data("not json".utf8).write(to: file)
        XCTAssertTrue(BundleCacheIndex.load(libraryRoot: dir).entries.isEmpty,
                      "a corrupt cache must never break an import")
        // Recording still works over a corrupt cache.
        BundleCacheIndex.record(sourceHash: "c", bundleID: "B", title: "T", libraryRoot: dir)
        XCTAssertEqual(BundleCacheIndex.lookup(sourceHash: "c", libraryRoot: dir), "B")
    }

    func testCacheIndexFileIsNotMistakenForABundle() {
        // The cache lives under a leading-dot name so the library scan (which
        // looks at bundle DIRECTORIES) never sees it as a bundle.
        XCTAssertTrue(BundleCacheIndex.fileName.hasPrefix("."))
        XCTAssertFalse(BundleCacheIndex.fileName.hasSuffix(".tmp"))
    }
}
