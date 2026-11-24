import XCTest
@testable import PitchLogic

// ModelManifest + ModelCacheNaming tests (J-207) — the on-device downloader
// reads the SAME manifest shape as `scripts/models/download.py` and
// `SwiftF0ModelStore.locateModel`, and caches under the EXISTING scheme
// `<name>-<sha256[:16]>` so the engine finds the file with the helper the CI
// parity jobs use.

final class ModelManifestTests: XCTestCase {

    private func manifestJSON(_ models: String) -> Data {
        Data("{\"models\": [\(models)]}".utf8)
    }

    func testParsesACompleteEntry() throws {
        let data = manifestJSON("""
        {
          "name": "htdemucs",
          "url": "https://huggingface.co/thesagezm/pitchnotes-models/resolve/main/htdemucs/ggml-model-htdemucs-4s-f16.bin",
          "sha256": "72b17c42d308982ddb50",
          "size": 83994361,
          "license": "MIT (Tier B per D-30: training-data risk recorded)"
        }
        """)
        let entries = try ModelManifest.entries(from: data)
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.name, "htdemucs")
        XCTAssertEqual(entry.sha256, "72b17c42d308982ddb50")
        XCTAssertEqual(entry.sizeBytes, 83_994_361)
        XCTAssertEqual(entry.license, "MIT (Tier B per D-30: training-data risk recorded)")
        XCTAssertTrue(entry.url.absoluteString.contains("htdemucs"))
    }

    func testEntriesWithoutATrustAnchorAreSkipped() throws {
        // No sha256 ⇒ not downloadable: an unverifiable file is never cached.
        let data = manifestJSON("""
        { "name": "no-anchor", "url": "https://example.com/x.bin", "size": 10 }
        """)
        let entries = try ModelManifest.entries(from: data)
        XCTAssertTrue(entries.isEmpty)
    }

    func testEntriesWithoutAURLOrNameAreSkipped() throws {
        let data = manifestJSON("""
        { "name": "no-url", "sha256": "abc", "size": 10 },
        { "url": "https://example.com/y.bin", "sha256": "abc" }
        """)
        let entries = try ModelManifest.entries(from: data)
        XCTAssertTrue(entries.isEmpty)
    }

    func testMalformedManifestIsReportedNotGuessed() {
        XCTAssertThrowsError(try ModelManifest.entries(from: Data("not json".utf8)))
        XCTAssertThrowsError(try ModelManifest.entries(from: Data("{\"other\": []}".utf8)))
    }

    func testLookupByName() throws {
        let data = manifestJSON("""
        { "name": "a", "url": "https://example.com/a", "sha256": "aa" },
        { "name": "b", "url": "https://example.com/b", "sha256": "bb" }
        """)
        let entries = try ModelManifest.entries(from: data)
        XCTAssertEqual(ModelManifest.entry(named: "b", in: entries)?.sha256, "bb")
        XCTAssertNil(ModelManifest.entry(named: "c", in: entries))
    }

    // MARK: - The cache naming scheme (must match scripts/models/download.py)

    func testCacheFileNameUsesTheExistingScheme() {
        let sha = "72b17c42d308982ddb50e3f0c1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f901"
        XCTAssertEqual(ModelCacheNaming.fileName(name: "htdemucs", sha256: sha),
                       "htdemucs-72b17c42d308982d")
    }

    func testCachedURLJoinsTheCacheDirectory() {
        let sha = "72b17c42d308982ddb50e3f0c1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f901"
        let dir = URL(fileURLWithPath: "/tmp/models", isDirectory: true)
        XCTAssertEqual(ModelCacheNaming.cachedURL(name: "htdemucs", sha256: sha, in: dir).path,
                       "/tmp/models/htdemucs-72b17c42d308982d")
    }

    func testSizeDescriptionIsHonestAboutUnknownSizes() {
        XCTAssertEqual(ModelCacheNaming.sizeDescription(bytes: nil), "size unknown")
        XCTAssertEqual(ModelCacheNaming.sizeDescription(bytes: 0), "size unknown")
        let text = ModelCacheNaming.sizeDescription(bytes: 83_994_361)
        XCTAssertTrue(text.contains("83,994,361"), "the exact byte count must be shown: \(text)")
        XCTAssertTrue(text.contains("MB"), "the human size must be shown: \(text)")
    }

    // MARK: - The bundled-manifest locator (J-207 last mile, X-207)

    func testManifestLocatorTriesTheBundleRootFirst() {
        let root = URL(fileURLWithPath: "/tmp/app.bundle", isDirectory: true)
        XCTAssertEqual(ModelManifestLocator.candidateRelativePaths.first, "manifest.json")
        XCTAssertEqual(ModelManifestLocator.candidateURLs(in: root).first?.path,
                       "/tmp/app.bundle/manifest.json")
    }

    func testManifestLocatorAlsoCoversTheModelsSubfolderLayout() {
        let root = URL(fileURLWithPath: "/tmp/app.bundle", isDirectory: true)
        XCTAssertTrue(
            ModelManifestLocator.candidateRelativePaths.contains("Models/manifest.json"),
            "XcodeGen can land a directory resource under Models/ — the lookup must cover it")
        let paths = ModelManifestLocator.candidateURLs(in: root).map(\.path)
        XCTAssertTrue(paths.contains("/tmp/app.bundle/Models/manifest.json"), "got \(paths)")
    }

    func testManifestLocatorPicksTheFirstExistingCandidate() {
        let root = URL(fileURLWithPath: "/tmp/app.bundle", isDirectory: true)
        let existing = ModelManifestLocator.candidateURLs(in: root)[1]
        let found = ModelManifestLocator.locate(in: root) { $0 == existing }
        XCTAssertEqual(found?.path, existing.path)
    }

    func testManifestLocatorPrefersTheRootWhenBothExist() {
        let root = URL(fileURLWithPath: "/tmp/app.bundle", isDirectory: true)
        let urls = ModelManifestLocator.candidateURLs(in: root)
        let found = ModelManifestLocator.locate(in: root) { _ in true }
        XCTAssertEqual(found?.path, urls[0].path)
    }

    func testManifestLocatorReturnsNilWhenNoManifestIsBundled() {
        let root = URL(fileURLWithPath: "/tmp/app.bundle", isDirectory: true)
        XCTAssertNil(ModelManifestLocator.locate(in: root) { _ in false })
    }

    func testManifestLocatorReportsItsRelativePathForTheDemo() {
        let root = URL(fileURLWithPath: "/tmp/app.bundle", isDirectory: true)
        let nested = ModelManifestLocator.candidateURLs(in: root)[1]
        XCTAssertEqual(ModelManifestLocator.relativePath(of: nested, in: root), "Models/manifest.json")
        let top = ModelManifestLocator.candidateURLs(in: root)[0]
        XCTAssertEqual(ModelManifestLocator.relativePath(of: top, in: root), "manifest.json")
    }
}
