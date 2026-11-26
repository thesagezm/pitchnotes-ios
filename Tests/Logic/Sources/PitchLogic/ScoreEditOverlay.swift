import Foundation
import EngineCore

// ScoreEditOverlay + ScoreEditStore (J-304) — WHERE THE SCORE'S NUDGE LIVES.
//
// RULED (C-16, D-47 §7): a manual time nudge of a SCORE note has no home in
// C-11. C-11's ops address the ENGINE's notes by index; the score is a
// DIFFERENT artifact in a DIFFERENT coordinate space, and mixing the two
// index spaces into one file would make them ambiguous. So the score's edits
// live in their own file, beside C-11's and C-15's:
//
//   <bundle>/corrections/score.json
//
//   { "contractVersion": "v1.1",
//     "scoreEdits": [ { "scoreIndex": 12, "offset_s": -0.025 } ] }
//
// THE RULES (C-16):
//   1. the file is OPTIONAL — absent ⇒ no nudges ⇒ exactly as before;
//   2. it moves the SCORE's times, NEVER the engine's notes: the engine's
//      `notes/<PART>.json` is immutable (C-11 rule 1) and the score-informed
//      track stays DERIVED (C-13 rule 3);
//   3. it is NOT a C-11 op — there is deliberately no `nudge` op in C-11;
//   4. a MISSING TARGET IS REPORTED, NEVER CLAMPED (the same posture as
//      C-11's split): a `scoreIndex` that does not exist in the score-note
//      list is skipped and reported.
//
// HONESTY ON AN UNREADABLE FILE: a file we cannot read is REPORTED (never
// silently treated as "no nudges"), and the user's bytes are never destroyed.

/// One score-note edit (C-16): an additive time offset in seconds.
public struct ScoreEdit: Codable, Equatable, Sendable {

    /// The index of the target note in C-13.1's `scoreNotes` array.
    public var scoreIndex: Int
    /// The additive offset in seconds (may be negative — earlier).
    public var offset_s: Double

    public init(scoreIndex: Int, offset_s: Double) {
        self.scoreIndex = scoreIndex
        self.offset_s = offset_s
    }
}

/// The score-edit overlay (C-16) — the file `corrections/score.json`.
public struct ScoreEditOverlay: Codable, Equatable, Sendable {

    public static let contractVersion = "v1.1"
    public static let writerEngineVersion = "corrections-0.1.0"

    public var contractVersion: String
    /// OPTIONAL — the writer of the overlay.
    public var engineVersion: String?
    /// The user's score-note time offsets, in order.
    public var scoreEdits: [ScoreEdit]

    public init(engineVersion: String? = ScoreEditOverlay.writerEngineVersion,
                scoreEdits: [ScoreEdit] = []) {
        self.contractVersion = ScoreEditOverlay.contractVersion
        self.engineVersion = engineVersion
        self.scoreEdits = scoreEdits
    }

    /// The edits as the review's `[scoreIndex: offset]` map.
    public var nudges: [Int: Double] {
        var map: [Int: Double] = [:]
        for edit in scoreEdits {
            map[edit.scoreIndex] = edit.offset_s
        }
        return map
    }

    /// The overlay for a set of nudges (the writer's view).
    ///
    /// The edits are ordered by `scoreIndex` so the file is stable and
    /// diffable.
    public init(nudges: [Int: Double]) {
        let edits = nudges
            .map { ScoreEdit(scoreIndex: $0.key, offset_s: $0.value) }
            .sorted { $0.scoreIndex < $1.scoreIndex }
        self.init(scoreEdits: edits)
    }

    /// True when the overlay carries no edits (⇒ the file is not worth
    /// writing).
    public var isEmpty: Bool { scoreEdits.isEmpty }
}

/// What was found on disk for a song's score edits.
public struct LoadedScoreEdits: Equatable, Sendable {
    /// The nudges, by score-note index.
    public var nudges: [Int: Double]
    /// Problems found while reading (each is REPORTED, never silent).
    public var problems: [String]
    /// True when a score-edit file exists on disk.
    public var foundAnyFile: Bool

    public init(nudges: [Int: Double] = [:], problems: [String] = [],
                foundAnyFile: Bool = false) {
        self.nudges = nudges
        self.problems = problems
        self.foundAnyFile = foundAnyFile
    }
}

/// Filesystem operations for the score-edit overlay (C-16).
///
/// Synchronous I/O — callers run them OFF the main thread (AGENTS §8); the
/// type is a plain struct over a URL with no shared mutable state.
public struct ScoreEditStore: Sendable {

    /// The bundle directory (the engine's bundle). The overlay lives in its
    /// `corrections/` subdirectory, beside C-11's and C-15's files.
    public let bundleDirectory: URL

    public init(bundleDirectory: URL) {
        self.bundleDirectory = bundleDirectory
    }

    /// `<bundle>/corrections/`.
    public var correctionsDirectory: URL {
        bundleDirectory.appendingPathComponent("corrections", isDirectory: true)
    }

    /// `corrections/score.json` (C-16's home).
    public func scoreOverlayURL() -> URL {
        correctionsDirectory.appendingPathComponent("score.json", isDirectory: false)
    }

    /// The quarantine copy for an unreadable file.
    public func corruptURL() -> URL {
        scoreOverlayURL().appendingPathExtension("corrupt")
    }

    // MARK: - Reading

    /// Reads the score edits. Never throws: a missing file ⇒ no nudges, an
    /// unreadable file is quarantined and reported.
    public func load() -> LoadedScoreEdits {
        let url = scoreOverlayURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return LoadedScoreEdits()
        }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            quarantine()
            return LoadedScoreEdits(
                problems: ["The score's time nudges could not be read; they were ignored (a copy was kept)."],
                foundAnyFile: true)
        }
        do {
            let overlay = try JSONDecoder().decode(ScoreEditOverlay.self, from: data)
            guard Self.isSupportedVersion(overlay.contractVersion) else {
                quarantine()
                return LoadedScoreEdits(
                    problems: ["The score's time nudges use schema \(overlay.contractVersion), and this build understands \(ScoreEditOverlay.contractVersion); they were ignored (a copy was kept)."],
                    foundAnyFile: true)
            }
            return LoadedScoreEdits(nudges: overlay.nudges, foundAnyFile: true)
        } catch {
            quarantine()
            return LoadedScoreEdits(
                problems: ["The score's time nudges could not be read; they were ignored (a copy was kept)."],
                foundAnyFile: true)
        }
    }

    // MARK: - Writing

    /// Writes the score edits (atomic). Empty ⇒ the file is REMOVED (absence
    /// means "no nudges", the same rule as C-11's per-part files).
    public func save(nudges: [Int: Double]) throws {
        guard !nudges.isEmpty else {
            try clear()
            return
        }
        let overlay = ScoreEditOverlay(nudges: nudges)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(overlay)
        try FileManager.default.createDirectory(at: correctionsDirectory,
                                                withIntermediateDirectories: true)
        try data.write(to: scoreOverlayURL(), options: [.atomic])
    }

    /// Removes the score-edit file (reversible — nothing else is touched).
    public func clear() throws {
        let url = scoreOverlayURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Helpers

    /// Refuses a schema this build does not understand (the same posture as
    /// `CorrectionStore`).
    static func isSupportedVersion(_ found: String) -> Bool {
        let major = found.split(separator: ".").first.map(String.init) ?? found
        return major == "v1"
    }

    /// Copies an unreadable file aside (the original stays until the user
    /// saves new edits).
    private func quarantine() {
        let fm = FileManager.default
        let url = scoreOverlayURL()
        guard fm.fileExists(atPath: url.path) else { return }
        let corrupt = corruptURL()
        try? fm.removeItem(at: corrupt)
        try? fm.copyItem(at: url, to: corrupt)
    }
}

// MARK: - The missing-target rule (C-16 rule 4)

extension ScoreEditOverlay {
    /// The edits that address a note which does not exist.
    ///
    /// C-16 rule 4: a MISSING TARGET IS REPORTED, NEVER CLAMPED — the edit is
    /// skipped (it never moves a note that is not there) and the user is told.
    public static func missingTargets(in nudges: [Int: Double],
                                      scoreNoteCount: Int) -> [Int] {
        nudges.keys.filter { $0 < 0 || $0 >= scoreNoteCount }.sorted()
    }
}
