import Foundation
import EngineCore

// BundleStore (J-201 producer side / J-202 consumer side) — the on-disk home
// of imported SongBundles plus the tiny JSON index that tracks them
// (D-4: JSON index v0 for M2; GRDB arrives in M4 for session history, NOT for
// this index).
//
// Consumer rule (C-2.2, FROZEN): a bundle directory is complete IFF it
// contains a parseable song.json. Library/scan code IGNORES `<…>.tmp`
// staging directories (and Settings cleanup may delete them) — a cancelled or
// killed import therefore never surfaces a partial song.

/// One imported song, as recorded in the index.
public struct BundleRecord: Codable, Identifiable, Equatable, Sendable {
    /// Manifest id (ULID) — also the bundle directory name.
    public let id: String
    public let title: String
    public let sourceFileName: String
    /// Security-scoped bookmark of the ORIGINAL imported file (provenance /
    /// possible re-import). Best-effort: nil when the bookmark could not be
    /// created. Never resolved automatically — audio is never re-read to
    /// mutate stored bundles (D-22: stored audio stays byte-true).
    public let sourceBookmark: Data?
    public let addedAt: Date
    public let duration_s: Double
    /// J-205/D-22: the user's tuning-reference override (UI-owned state in
    /// the index — the manifest's `tuning_cents` itself is engine-authored
    /// and never rewritten). Optional + defaulted: pre-J-205 index JSON
    /// (and pre-J-205 call sites) decode unchanged.
    public let tuningOverride: TuningOverride?

    public init(id: String, title: String, sourceFileName: String,
                sourceBookmark: Data?, addedAt: Date, duration_s: Double,
                tuningOverride: TuningOverride? = nil) {
        self.id = id
        self.title = title
        self.sourceFileName = sourceFileName
        self.sourceBookmark = sourceBookmark
        self.addedAt = addedAt
        self.duration_s = duration_s
        self.tuningOverride = tuningOverride
    }
}

struct BundleIndexFile: Codable, Equatable, Sendable {
    var version: Int = 1
    var records: [BundleRecord] = []
}

public enum BundleStoreError: Error, Equatable, Sendable {
    case bundleNotFound(String)
    case bundleIncomplete(String)
}

/// Filesystem + index operations for the bundle root. Methods are synchronous
/// file I/O — callers invoke them OFF the main thread (AGENTS §8); the type is
/// a plain struct over a root URL and carries no shared mutable state.
public struct BundleStore: Sendable {

    /// …/Bundles — one imported-song directory per child.
    public let root: URL
    /// …/Bundles/index.json (D-4 JSON index v0).
    public let indexURL: URL

    public init(directory: URL) {
        self.root = directory
        self.indexURL = directory.appendingPathComponent("index.json", isDirectory: false)
    }

    /// Default location (Application Support/PitchNotes/Bundles), creating the
    /// directory chain if needed.
    public static func makeDefault() throws -> BundleStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = base
            .appendingPathComponent("PitchNotes", isDirectory: true)
            .appendingPathComponent("Bundles", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return BundleStore(directory: dir)
    }

    // MARK: - Index

    /// Loads the index. Corrupt/missing index → empty (the corrupt file is
    /// preserved as index.corrupt so nothing is silently destroyed); `scan`
    /// then rebuilds truth from disk (the bundles themselves carry song.json).
    public func loadIndex() -> [BundleRecord] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        do {
            // MUST mirror saveIndex's .iso8601 date strategy — a decoder on the
            // default strategy throws on ISO-8601 dates and silently quarantines
            // a perfectly good index (every record would "vanish" on relaunch;
            // caught by CI r3, run 45011496301).
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(BundleIndexFile.self, from: data).records
        } catch {
            let corrupt = indexURL.deletingLastPathComponent()
                .appendingPathComponent("index.corrupt")
            try? FileManager.default.removeItem(at: corrupt)
            try? FileManager.default.copyItem(at: indexURL, to: corrupt)
            return []
        }
    }

    /// Writes the index (sorted newest-first, the display order).
    public func saveIndex(_ records: [BundleRecord]) throws {
        let sorted = records.sorted { $0.addedAt > $1.addedAt }
        let file = BundleIndexFile(records: sorted)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(file)
        // Atomic index write (same discipline as bundle writes, C-2.2).
        try data.write(to: indexURL, options: [.atomic])
    }

    /// Adds/updates one record (dedupe by id; newest-first on save).
    public func register(_ record: BundleRecord) throws {
        var records = loadIndex().filter { $0.id != record.id }
        records.append(record)
        try saveIndex(records)
    }

    // MARK: - Scan (disk truth — the honesty layer)

    /// Disk truth: every root child directory that is a COMPLETE bundle
    /// (parseable song.json). `*.tmp` staging dirs are ignored per C-2.2.
    /// Records whose directory vanished or became incomplete are excluded
    /// (call `reconcile` to persist that pruning).
    public func scan() -> [BundleRecord] {
        let indexed = loadIndex()
        let fm = FileManager.default
        var surviving: [BundleRecord] = []
        for record in indexed {
            let dir = root.appendingPathComponent(record.id, isDirectory: true)
            guard isCompleteBundle(at: dir) else { continue }
            surviving.append(record)
        }
        // A bundle present on disk but missing from the index (crash between
        // rename and index write) is ADOPTED from its manifest — disk truth
        // wins over index gaps.
        let knownIDs = Set(surviving.map(\.id))
        if let children = try? fm.contentsOfDirectory(atPath: root.path) {
            for child in children where !child.hasSuffix(".tmp") && child != "index.json" && !child.hasPrefix(".") {
                guard !knownIDs.contains(child) else { continue }
                let dir = root.appendingPathComponent(child, isDirectory: true)
                if let manifest = readManifest(at: dir) {
                    let creation = (try? fm.attributesOfItem(atPath: dir.path))?[
                        .creationDate] as? Date ?? Date()
                    surviving.append(BundleRecord(
                        id: manifest.id,
                        title: manifest.title,
                        sourceFileName: "",
                        sourceBookmark: nil,
                        addedAt: creation,
                        duration_s: manifest.duration_s))
                }
            }
        }
        return surviving.sorted { $0.addedAt > $1.addedAt }
    }

    /// Persists the pruned scan result (index entries without a complete
    /// bundle on disk are dropped).
    public func reconcile() throws {
        try saveIndex(scan())
    }

    /// C-2.2 consumer rule: complete IFF song.json exists AND parses.
    public func isCompleteBundle(at dir: URL) -> Bool {
        readManifest(at: dir) != nil
    }

    public func readManifest(at dir: URL) -> SongManifest? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("song.json")) else {
            return nil
        }
        return try? JSONDecoder().decode(SongManifest.self, from: data)
    }

    // MARK: - Tuning override (J-205, D-22)

    /// Persists the user's tuning-reference override for one song (nil clears
    /// back to the recording default). Pure index edit — the manifest and the
    /// stored audio are never touched (D-22 byte-true rule).
    public func setTuningOverride(_ override: TuningOverride?, forID id: String) throws {
        var records = loadIndex()
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw BundleStoreError.bundleNotFound(id)
        }
        records[index] = BundleRecord(
            id: records[index].id,
            title: records[index].title,
            sourceFileName: records[index].sourceFileName,
            sourceBookmark: records[index].sourceBookmark,
            addedAt: records[index].addedAt,
            duration_s: records[index].duration_s,
            tuningOverride: override)
        try saveIndex(records)
    }

    /// The stored override for one song (nil = recording default / unknown id).
    public func tuningOverride(forID id: String) -> TuningOverride? {
        loadIndex().first { $0.id == id }?.tuningOverride
    }

    // MARK: - Staging + deletion

    /// Staging directory for an in-flight import (C-2.2: `<id>.tmp` adjacent
    /// to the final bundle). Consumers ignore it; cleanup deletes it.
    public func stagingDirectory(forID id: String) -> URL {
        root.appendingPathComponent("\(id).tmp", isDirectory: true)
    }

    /// Deletes leftover staging dirs from cancelled/killed imports. Returns
    /// how many were removed (Settings → Storage shows the number).
    @discardableResult
    public func clearStrayStagingDirectories() -> Int {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(atPath: root.path) else { return 0 }
        var removed = 0
        for child in children where child.hasSuffix(".tmp") {
            if (try? fm.removeItem(at: root.appendingPathComponent(child, isDirectory: true))) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// How many stray `<id>.tmp` staging dirs exist right now (Settings →
    /// Storage's "interrupted imports" row; cleanup reuses the clear method).
    public func strayStagingDirectoryCount() -> Int {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(atPath: root.path) else { return 0 }
        return children.filter { $0.hasSuffix(".tmp") }.count
    }

    /// Deletes one song: bundle directory first, then the index entry. If the
    /// process dies between the two, `scan`/`reconcile` heal the index (the
    /// record points at a missing dir and is pruned). Never deletes anything
    /// outside `root`.
    public func delete(id: String) throws {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw BundleStoreError.bundleNotFound(id)
        }
        try FileManager.default.removeItem(at: dir)
        try saveIndex(loadIndex().filter { $0.id != id })
    }

    /// Total bytes occupied by the bundle root (bundles + index; staging dirs
    /// counted too — Settings → Storage surfaces them for cleanup).
    public func totalBytesOnDisk() -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Bytes occupied by ONE bundle directory (manifest + stems + notes/pitch
    /// files) — the per-song row in the Library. 0 when the bundle is absent
    /// (scan already prunes records whose directory vanished). Staging dirs of
    /// OTHER imports are adjacent (`<id>.tmp`), never inside, so they don't
    /// pollute a bundle's size.
    public func bytesOnDisk(forID id: String) -> Int64 {
        let fm = FileManager.default
        let dir = root.appendingPathComponent(id, isDirectory: true)
        guard let enumerator = fm.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
