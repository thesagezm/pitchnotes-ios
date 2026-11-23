import Foundation

// P-204 · Import cache index (engine side).
//
// WHAT THIS IS: a tiny, engine-owned JSON map from the SOURCE HASH (BLAKE3 of
// the original imported bytes, C-2.1) to the bundle id it produced. It lets
// the import path answer "was this exact file already imported?" without
// scanning every bundle, and it lets a re-import reuse the existing bundle
// instead of publishing a duplicate.
//
// WHAT THIS IS NOT: the LIBRARY index (D-4: the library's JSON index is
// J-202's, Jess's lane — the app's song list). This file lives under a
// LEADING-DOT name so the library scan (which looks at bundle DIRECTORIES)
// never mistakes it for a bundle, and the two never write the same file.
//
// The index is a CACHE, not a source of truth: a missing, corrupt or stale
// index never breaks an import — every read is best-effort and every write is
// atomic (temp file + rename).

public struct BundleCacheIndex: Codable, Equatable, Sendable {

    /// Cache format version (bump only on a breaking shape change).
    public static let currentVersion = "v0"

    /// One remembered import.
    public struct Entry: Codable, Equatable, Sendable {
        /// BLAKE3 hex of the original imported file bytes (C-2.1 sourceHash).
        public var sourceHash: String
        /// The bundle id (= the published bundle directory name).
        public var bundleID: String
        /// Title as imported (display convenience; the bundle's song.json is
        /// the authority).
        public var title: String

        public init(sourceHash: String, bundleID: String, title: String) {
            self.sourceHash = sourceHash
            self.bundleID = bundleID
            self.title = title
        }
    }

    public var version: String
    public var entries: [Entry]

    public init(version: String = BundleCacheIndex.currentVersion, entries: [Entry] = []) {
        self.version = version
        self.entries = entries
    }

    /// The index file's name inside the library root (leading dot ⇒ never
    /// mistaken for a bundle directory by the library scan).
    public static let fileName = ".pitchnotes-import-cache.json"

    /// The index file's URL inside a library root.
    public static func url(inLibraryRoot root: URL) -> URL {
        root.appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: - Read / write (best-effort; the cache never breaks an import)

    /// Loads the index. A missing or unreadable file yields an EMPTY index
    /// (the cache is disposable).
    public static func load(libraryRoot: URL) -> BundleCacheIndex {
        guard let data = try? Data(contentsOf: url(inLibraryRoot: libraryRoot)),
              let decoded = try? JSONDecoder().decode(BundleCacheIndex.self, from: data)
        else { return BundleCacheIndex() }
        return decoded
    }

    /// Writes the index atomically (temp file + rename inside the library
    /// root). Failures are swallowed: a cache write must never fail an import
    /// that already published its bundle.
    ///
    /// The rename is `FileManager.moveItem` (POSIX rename(2)) — portable on
    /// Linux and Apple (the old `replaceItemAt` is unavailable/broken on
    /// corelibs-Foundation, which silently dropped every cache write).
    public static func save(_ index: BundleCacheIndex, libraryRoot: URL) {
        let fm = FileManager.default
        let target = url(inLibraryRoot: libraryRoot)
        let temp = libraryRoot.appendingPathComponent(fileName + ".tmp", isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(index) else { return }
        do {
            try fm.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
            try? fm.removeItem(at: temp)
            try data.write(to: temp)
            // POSIX rename replaces the destination atomically, but
            // FileManager.moveItem refuses an existing destination on some
            // platforms — remove first (the cache is disposable, the window
            // is microseconds, and a crash here only loses the cache).
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: temp, to: target)
        } catch {
            try? fm.removeItem(at: temp)
        }
    }

    /// Records (or refreshes) the mapping for one import and saves the index.
    /// - Returns: the updated index (also handy for tests).
    @discardableResult
    public static func record(sourceHash: String, bundleID: String, title: String,
                              libraryRoot: URL) -> BundleCacheIndex {
        var index = load(libraryRoot: libraryRoot)
        index.entries.removeAll { $0.sourceHash == sourceHash || $0.bundleID == bundleID }
        index.entries.append(Entry(sourceHash: sourceHash, bundleID: bundleID, title: title))
        save(index, libraryRoot: libraryRoot)
        return index
    }

    /// The bundle id previously produced for this source hash (nil when the
    /// file was never imported, or the cache does not know).
    public static func lookup(sourceHash: String, libraryRoot: URL) -> String? {
        load(libraryRoot: libraryRoot).entries.first { $0.sourceHash == sourceHash }?.bundleID
    }

    /// Drops the entries whose bundle no longer exists on disk (the bundle was
    /// deleted by the user) and saves the pruned index.
    @discardableResult
    public static func prune(libraryRoot: URL) -> BundleCacheIndex {
        var index = load(libraryRoot: libraryRoot)
        let fm = FileManager.default
        index.entries.removeAll { entry in
            !fm.fileExists(atPath: libraryRoot.appendingPathComponent(entry.bundleID).path)
        }
        save(index, libraryRoot: libraryRoot)
        return index
    }
}
