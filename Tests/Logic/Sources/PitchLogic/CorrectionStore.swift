import Foundation
import EngineCore

// CorrectionStore (J-302) — where a song's corrections live.
//
// WHERE (and why NOT in the bundle):
//   the bundle directory is PAUL's and its contents are contract-validated
//   (C-2.3 V7–V10, C-2.2 atomic writes). Writing an extra file into it would
//   change a contract-checked directory, so the corrections live in JESS's
//   own store — the same pattern as `BundleStore`'s JSON index (D-4):
//
//       Application Support/PitchNotes/Corrections/<bundleID>.json
//
//   keyed by the manifest id, so a correction follows its song and survives
//   a relaunch.
//
// THE RAW TRACKS ARE NEVER TOUCHED: the store holds the overlay only. Clear
// the overlay and the engine's output is back, exactly (reversible).
//
// HONESTY ON A CORRUPT FILE: a file we cannot read is QUARANTINED (copied to
// `<bundleID>.corrupt`, the original left alone until the user saves) and
// the app says so — it never silently shows "no corrections" as if the user
// had never made any, and it never crashes.

/// The outcome of reading one song's overlay.
public enum CorrectionLoadResult: Equatable, Sendable {
    /// There is no overlay for this song (no corrections yet).
    case absent
    /// The overlay was read.
    case loaded(CorrectionOverlay)
    /// The file exists but could not be understood. The reason is for the
    /// UI; the file has been quarantined.
    case corrupted(reason: String)
}

public enum CorrectionStoreError: Error, Equatable, Sendable {
    /// The overlay was written by a newer schema than this build knows.
    case unknownVersion(found: Int, supported: Int)
}

/// Filesystem operations for the correction overlays. Synchronous I/O —
/// callers run them OFF the main thread (AGENTS §8); the type is a plain
/// struct over a root URL with no shared mutable state.
public struct CorrectionStore: Sendable {

    /// …/Corrections — one JSON file per song.
    public let root: URL

    public init(directory: URL) {
        self.root = directory
    }

    /// Default location (Application Support/PitchNotes/Corrections).
    public static func makeDefault() throws -> CorrectionStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = base
            .appendingPathComponent("PitchNotes", isDirectory: true)
            .appendingPathComponent("Corrections", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return CorrectionStore(directory: dir)
    }

    /// The overlay file for one song.
    public func overlayURL(forBundleID id: String) -> URL {
        root.appendingPathComponent("\(id).json", isDirectory: false)
    }

    /// The quarantine copy for an unreadable file.
    public func corruptURL(forBundleID id: String) -> URL {
        root.appendingPathComponent("\(id).corrupt", isDirectory: false)
    }

    // MARK: - Reading

    /// Reads one song's overlay. Never throws: an absent file is `.absent`,
    /// an unreadable one is `.corrupted` (and is quarantined).
    public func loadResult(forBundleID id: String) -> CorrectionLoadResult {
        let url = overlayURL(forBundleID: id)
        guard let data = try? Data(contentsOf: url) else { return .absent }
        do {
            let decoder = JSONDecoder()
            // MUST mirror save's date strategy (the ISO-8601 lesson from the
            // bundle index, CI r3): a decoder on the default strategy throws
            // on an ISO-8601 date and the user's corrections would "vanish".
            decoder.dateDecodingStrategy = .iso8601
            let overlay = try decoder.decode(CorrectionOverlay.self, from: data)
            guard overlay.version <= CorrectionOverlay.currentVersion else {
                let reason = "It was written by a newer version of PitchNotes (schema \(overlay.version); this build understands \(CorrectionOverlay.currentVersion))."
                quarantine(id: id)
                return .corrupted(reason: reason)
            }
            return .loaded(overlay)
        } catch {
            let reason = "The correction file could not be read (\(error.localizedDescription))."
            quarantine(id: id)
            return .corrupted(reason: reason)
        }
    }

    /// The overlay for one song — EMPTY when there is none or it is
    /// unreadable (the caller shows the `loadResult` reason when it matters).
    public func load(forBundleID id: String) -> CorrectionOverlay {
        switch loadResult(forBundleID: id) {
        case let .loaded(overlay): return overlay
        case .absent: return .empty(bundleID: id)
        case .corrupted: return .empty(bundleID: id)
        }
    }

    /// Every song that has corrections on disk.
    public func bundleIDsWithOverlays() -> [String] {
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        return children
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
            .sorted()
    }

    // MARK: - Writing

    /// Writes the overlay (atomic). Refuses a schema this build does not
    /// understand, so a newer file is never downgraded by accident.
    public func save(_ overlay: CorrectionOverlay) throws {
        guard overlay.version <= CorrectionOverlay.currentVersion else {
            throw CorrectionStoreError.unknownVersion(found: overlay.version,
                                                      supported: CorrectionOverlay.currentVersion)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(overlay)
        try data.write(to: overlayURL(forBundleID: overlay.bundleID), options: [.atomic])
    }

    /// Removes a song's corrections (reversible — the engine's tracks are
    /// untouched, so the song simply goes back to the engine's opinion).
    public func clear(forBundleID id: String) throws {
        let url = overlayURL(forBundleID: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Quarantine

    /// Copies an unreadable file aside (the original stays until the user
    /// saves a new overlay). An existing quarantine copy is replaced — it is
    /// a copy of a file we could not read, not user data we would lose.
    private func quarantine(id: String) {
        let url = overlayURL(forBundleID: id)
        let corrupt = corruptURL(forBundleID: id)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        try? fm.removeItem(at: corrupt)
        try? fm.copyItem(at: url, to: corrupt)
    }
}
