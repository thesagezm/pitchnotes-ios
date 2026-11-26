import Foundation
import EngineCore

// CorrectionStore (J-302) — where a song's corrections live.
//
// WHERE (CONTRACTS v1.1 · C-11):
//   the overlay lives BESIDE the bundle's notes, INSIDE the bundle directory:
//
//       <bundle>/corrections/<PART>.json    one file per corrected part
//       <bundle>/corrections/song.json      the renames + range overrides
//                                            (X-216 proposal — Leto rules)
//
//   A part with no corrections has NO FILE: absence means "no corrections",
//   never "unknown" (C-11).
//
// THE RAW TRACKS ARE NEVER TOUCHED: the store holds the overlay only. Clear
// the overlay and the engine's output is back, exactly (reversible).
//
// HONESTY ON A CORRUPT FILE: a file we cannot read is QUARANTINED (copied to
// `<PART>.json.corrupt`, the original left alone until the user saves) and
// the app says so — it never silently shows "no corrections" as if the user
// had never made any, and it never crashes.
//
// THE CONTRACT VERSION IS CHECKED: a file whose MAJOR is not "v1" is REFUSED
// (never mis-read) and reported.

/// What was found on disk for one song.
public struct LoadedCorrections: Equatable, Sendable {
    /// The per-part overlays, keyed by part.
    public var partOverlays: [Part: PartCorrectionOverlay]
    /// The per-song calibration (renames + range overrides), if present.
    public var calibration: SongCalibrationOverlay?
    /// Problems found while reading (each is REPORTED, never silent).
    public var problems: [String]
    /// True when at least one correction file exists on disk.
    public var foundAnyFile: Bool

    public init(partOverlays: [Part: PartCorrectionOverlay] = [:],
                calibration: SongCalibrationOverlay? = nil,
                problems: [String] = [],
                foundAnyFile: Bool = false) {
        self.partOverlays = partOverlays
        self.calibration = calibration
        self.problems = problems
        self.foundAnyFile = foundAnyFile
    }

    /// True when nothing was found (no corrections yet).
    public var isEmpty: Bool {
        partOverlays.values.allSatisfy(\.isEmpty)
            && (calibration?.isEmpty ?? true)
    }

    /// How many note corrections are stored.
    public var correctionCount: Int {
        partOverlays.values.reduce(0) { $0 + $1.operations.count }
    }
}

/// The outcome of reading a song's corrections.
public enum CorrectionLoadResult: Equatable, Sendable {
    /// There is no correction file at all (no corrections yet).
    case absent
    /// At least one file was read. `problems` carries anything that could
    /// not be read (those files are quarantined and reported).
    case loaded(LoadedCorrections)
    /// The corrections directory could not be opened at all.
    case failed(reason: String)
}

public enum CorrectionStoreError: Error, Equatable, Sendable {
    /// The overlay was written by a schema this build does not understand.
    case unknownContractVersion(found: String, supported: String)
    /// The overlay's `part` does not match the file it lives in.
    case partMismatch(file: String, declared: String, expected: String)
}

/// Filesystem operations for the correction overlays. Synchronous I/O —
/// callers run them OFF the main thread (AGENTS §8); the type is a plain
/// struct over a URL with no shared mutable state.
public struct CorrectionStore: Sendable {

    /// The bundle directory (the engine's bundle). The corrections live in
    /// its `corrections/` subdirectory (C-11).
    public let bundleDirectory: URL

    public init(bundleDirectory: URL) {
        self.bundleDirectory = bundleDirectory
    }

    /// `<bundle>/corrections/`.
    public var correctionsDirectory: URL {
        bundleDirectory.appendingPathComponent("corrections", isDirectory: true)
    }

    /// `corrections/<PART>.json`.
    public func overlayURL(for part: Part) -> URL {
        correctionsDirectory.appendingPathComponent("\(part.rawValue).json", isDirectory: false)
    }

    /// `corrections/song.json` (the renames + range overrides).
    public func songOverlayURL() -> URL {
        correctionsDirectory.appendingPathComponent("song.json", isDirectory: false)
    }

    /// The quarantine copy for an unreadable file.
    public func corruptURL(for part: Part) -> URL {
        correctionsDirectory.appendingPathComponent("\(part.rawValue).json.corrupt", isDirectory: false)
    }

    // MARK: - Reading

    /// Reads every correction file for this song. Never throws: a missing
    /// directory is `.absent`, an unreadable FILE is quarantined and reported
    /// inside `LoadedCorrections.problems`.
    public func loadResult() -> CorrectionLoadResult {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: correctionsDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .absent
        }
        guard let names = try? fm.contentsOfDirectory(atPath: correctionsDirectory.path) else {
            return .failed(reason: "Your corrections for this song could not be opened.")
        }

        var loaded = LoadedCorrections()
        var sawAny = false

        for name in names.sorted() {
            guard name.hasSuffix(".json") else { continue }
            sawAny = true
            let url = correctionsDirectory.appendingPathComponent(name, isDirectory: false)
            let data = fm.contents(atPath: url.path)

            if name == "song.json" {
                loaded.calibration = decodeCalibration(data, name: name, problems: &loaded.problems)
                continue
            }
            if name == "score.json" {
                // C-16's file — the SCORE's time nudges. It is read by
                // `ScoreEditStore`, not by this store, and it is NOT an
                // unknown part: it must never be quarantined here.
                continue
            }
            guard let part = Part(rawValue: String(name.dropLast(".json".count))) else {
                loaded.problems.append("The correction file '\(name)' does not name a known part; it was ignored (a copy was kept).")
                quarantine(url: url, as: url.appendingPathExtension("corrupt"))
                continue
            }
            if let overlay = decodePartOverlay(data, part: part, problems: &loaded.problems) {
                loaded.partOverlays[part] = overlay
            }
        }

        loaded.foundAnyFile = sawAny
        return .loaded(loaded)
    }

    /// The corrections for this song — EMPTY when there are none or they
    /// could not be read (the caller shows `loadResult`'s reason).
    public func load() -> LoadedCorrections {
        switch loadResult() {
        case let .loaded(loaded): return loaded
        case .absent: return LoadedCorrections()
        case .failed: return LoadedCorrections()
        }
    }

    // MARK: - Writing

    /// Writes one part's overlay (atomic). Refuses a schema this build does
    /// not understand, so a newer file is never downgraded by accident.
    public func save(_ overlay: PartCorrectionOverlay) throws {
        try requireSupportedVersion(overlay.contractVersion)
        let data = try encoder().encode(overlay)
        try write(data, to: overlayURL(for: overlay.part))
    }

    /// Writes the per-song calibration (the renames + range overrides).
    public func save(calibration: SongCalibrationOverlay) throws {
        try requireSupportedVersion(calibration.contractVersion)
        let data = try encoder().encode(calibration)
        try write(data, to: songOverlayURL())
    }

    /// Removes one part's corrections (reversible — the engine's tracks are
    /// untouched, so the song simply goes back to the engine's opinion).
    public func clear(part: Part) throws {
        let url = overlayURL(for: part)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Removes the per-song calibration (the renames + range overrides).
    ///
    /// The part overlays are NOT touched — the calibration is the user's
    /// display preference, not a correction to the engine's notes.
    public func clearCalibration() throws {
        let url = songOverlayURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Removes EVERY correction for this song — the part overlays AND the
    /// calibration. The engine's tracks are never touched.
    public func clearAll() throws {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: correctionsDirectory.path) else { return }
        for name in names where name.hasSuffix(".json") {
            let url = correctionsDirectory.appendingPathComponent(name, isDirectory: false)
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - Helpers

    /// The JSON encoder the overlay files use (pretty + sorted keys, so a
    /// human can read and diff them).
    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }

    /// Writes the bytes atomically, creating the corrections directory first.
    private func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: correctionsDirectory, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    /// Refuses a schema this build does not understand.
    private func requireSupportedVersion(_ found: String) throws {
        let major = found.split(separator: ".").first.map(String.init) ?? found
        guard major == "v1" else {
            throw CorrectionStoreError.unknownContractVersion(found: found,
                                                              supported: PartCorrectionOverlay.contractVersion)
        }
    }

    /// Decodes one part's overlay, reporting (and quarantining) anything that
    /// does not fit.
    private func decodePartOverlay(_ data: Data?,
                                   part: Part,
                                   problems: inout [String]) -> PartCorrectionOverlay? {
        guard let data else {
            problems.append("The correction file for \(part.displayName) could not be read; it was ignored (a copy was kept).")
            return nil
        }
        do {
            let overlay = try JSONDecoder().decode(PartCorrectionOverlay.self, from: data)
            try requireSupportedVersion(overlay.contractVersion)
            guard overlay.part == part else {
                problems.append("The correction file for \(part.displayName) says it is for \(overlay.part.displayName); it was ignored (a copy was kept).")
                quarantine(url: overlayURL(for: part),
                           as: corruptURL(for: part))
                return nil
            }
            return overlay
        } catch {
            let reason = describe(error)
            problems.append("Your \(part.displayName) corrections could not be read (\(reason)); they were ignored (a copy was kept).")
            quarantine(url: overlayURL(for: part), as: corruptURL(for: part))
            return nil
        }
    }

    /// Decodes the per-song calibration, reporting (and quarantining)
    /// anything that does not fit.
    private func decodeCalibration(_ data: Data?,
                                   name: String,
                                   problems: inout [String]) -> SongCalibrationOverlay? {
        guard let data else {
            problems.append("The song's correction file ('\(name)') could not be read; it was ignored (a copy was kept).")
            return nil
        }
        do {
            let calibration = try JSONDecoder().decode(SongCalibrationOverlay.self, from: data)
            try requireSupportedVersion(calibration.contractVersion)
            return calibration
        } catch {
            let reason = describe(error)
            problems.append("The song's correction file could not be read (\(reason)); the renames and ranges were ignored (a copy was kept).")
            quarantine(url: songOverlayURL(),
                       as: songOverlayURL().appendingPathExtension("corrupt"))
            return nil
        }
    }

    /// A human-readable reason for a decoding failure.
    private func describe(_ error: Error) -> String {
        if let storeError = error as? CorrectionStoreError {
            switch storeError {
            case let .unknownContractVersion(found, supported):
                return "it uses schema \(found), and this build understands \(supported)"
            case let .partMismatch(file, declared, expected):
                return "the file '\(file)' says \(declared) but should say \(expected)"
            }
        }
        if let decodingError = error as? DecodingError {
            switch decodingError {
            case let .dataCorrupted(context):
                return context.debugDescription
            case let .keyNotFound(key, _):
                return "the key '\(key.stringValue)' is missing"
            case let .typeMismatch(_, context):
                return context.debugDescription
            case let .valueNotFound(_, context):
                return context.debugDescription
            @unknown default:
                return "the file does not match the expected shape"
            }
        }
        return error.localizedDescription
    }

    /// Copies an unreadable file aside (the original stays until the user
    /// saves a new overlay). An existing quarantine copy is replaced — it is
    /// a copy of a file we could not read, not user data we would lose.
    private func quarantine(url: URL, as corrupt: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        try? fm.removeItem(at: corrupt)
        try? fm.copyItem(at: url, to: corrupt)
    }
}
