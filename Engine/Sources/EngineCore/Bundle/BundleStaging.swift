import Foundation

// P-202 L4 · Atomic bundle staging (CONTRACTS.md C-2.2, FROZEN at v1.0):
//
//   <library-root>/<id>.tmp   ← staging (everything is written HERE)
//   <library-root>/<id>       ← the published bundle (the RENAME is the publish)
//
// Rules implemented here:
//  - the staging directory is ADJACENT to the final bundle location (same
//    parent ⇒ the rename stays on one filesystem ⇒ it is atomic);
//  - `publish()` is the ONLY way a bundle becomes visible to a consumer;
//  - `discard()` removes the staging directory — on ANY failure, cancellation
//    or app kill mid-import, a cancelled job leaves NO partial bundle
//    (C-2.2 / C-8);
//  - `song.json` inside the bundle is the completion marker (written last);
//  - the bundle id is a DIRECTORY NAME only (C-9 rule 4: no path separators,
//    no "..") — this is ENFORCED here, not assumed by callers.
//
// The type is intentionally tiny and Foundation-only: the Linux-testable core
// owns the discipline, the Apple-side engines (P-204) only supply the bytes.

public final class BundleStaging {

    /// The song id == the published bundle directory name (C-2: "One directory
    /// per song, named by the song `id`"; C-9 rule 4: directory name only).
    public let bundleID: String

    /// The library root that holds every published bundle.
    public let libraryRoot: URL

    /// `<library-root>/<id>.tmp` — the staging directory (C-2.2).
    public var stagingURL: URL {
        libraryRoot.appendingPathComponent(bundleID + ".tmp", isDirectory: true)
    }

    /// `<library-root>/<id>` — the published bundle.
    public var publishedURL: URL {
        libraryRoot.appendingPathComponent(bundleID, isDirectory: true)
    }

    /// `<staging>/stems` — where the encoded stems land (C-2 layout).
    public var stemsURL: URL {
        stagingURL.appendingPathComponent("stems", isDirectory: true)
    }

    /// True while the staging directory exists (i.e. the import has NOT been
    /// published and NOT been discarded).
    public var hasStaging: Bool {
        FileManager.default.fileExists(atPath: stagingURL.path)
    }

    /// - Throws: `EngineError.contractViolation` when the id is not a plain
    ///   directory name (C-9 rule 4) — the id is never sanitised, because a
    ///   sanitised id would not match `song.json`'s `id` field.
    public init(libraryRoot: URL, bundleID: String) throws {
        guard BundleStaging.isValidBundleID(bundleID) else {
            throw EngineError.contractViolation(
                "bundle id \(bundleID.debugDescription) is not a plain directory name (C-9 rule 4)")
        }
        self.bundleID = bundleID
        self.libraryRoot = libraryRoot
    }

    /// C-9 rule 4 + C-2.2: the id is a directory name only — no path
    /// separators, no "." / "..", no traversal. The charset is deliberately
    /// conservative (letters, digits, dash, underscore): ULIDs — the engine's
    /// own ids — satisfy it, and anything else is rejected rather than
    /// silently rewritten.
    public static func isValidBundleID(_ id: String) -> Bool {
        guard !id.isEmpty, id != ".", id != ".." else { return false }
        guard !id.contains("/"), !id.contains("\\"), !id.contains("\0") else { return false }
        return id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// Creates a FRESH staging directory (with its `stems/` subdirectory).
    /// A stale `<id>.tmp` from a crashed previous run is removed first — a
    /// staging directory is never a valid bundle (C-2.2 consumer rule).
    @discardableResult
    public func create() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        if fm.fileExists(atPath: stagingURL.path) {
            try fm.removeItem(at: stagingURL)
        }
        try fm.createDirectory(at: stemsURL, withIntermediateDirectories: true)
        return stagingURL
    }

    /// Publishes the bundle: renames the staging directory to the final path.
    /// THIS RENAME IS THE PUBLISH (C-2.2). Before it, no bundle exists; after
    /// it, the bundle is complete (it contains a parseable `song.json`).
    ///
    /// Refuses to replace an existing published bundle — a published bundle is
    /// user data (C-2.2), never silently overwritten.
    public func publish() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: stagingURL.path) else {
            throw EngineError.importFailed(
                "bundle staging \(stagingURL.path) vanished before publish")
        }
        guard !fm.fileExists(atPath: publishedURL.path) else {
            throw EngineError.importFailed(
                "bundle \(publishedURL.path) already exists — refusing to replace a published bundle")
        }
        try fm.moveItem(at: stagingURL, to: publishedURL)
    }

    /// Removes the staging directory if present. Never throws — cleanup must
    /// not mask the original error (the caller rethrows its own).
    public func discard() {
        try? FileManager.default.removeItem(at: stagingURL)
    }
}
