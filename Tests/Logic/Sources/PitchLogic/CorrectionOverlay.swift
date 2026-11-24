import Foundation
import EngineCore

// CorrectionOverlay (J-302) — the USER's corrections to the engine's note
// tracks, as an ADDITIVE and REVERSIBLE layer.
//
// WHY A LAYER AND NOT AN EDIT (AGENTS §7 + D-41 §4):
//   · the engine's `notes/<PART>.json` is PAUL's output and is contract-
//     validated (C-2.3 V7–V10). Jess NEVER rewrites it.
//   · the overlay is the USER's opinion: "this note is T2, not T1", "this is
//     not a note at all", "this is two notes", "this part is called 'Tenor'".
//   · D-41 §4: the OVERLAY IS AUTHORITATIVE for grading — so every consumer
//     reads the corrected tracks through `CorrectionResolver.resolve`, never
//     the raw file.
//   · REVERSIBLE: clearing the overlay restores the engine's output exactly
//     (the raw tracks are never touched, so "undo" is lossless).
//
// THE SCHEMA IS NOT YET RATIFIED (L-301 is TODO). This file defines a stable,
// versioned shape and the EXACT JSON is filed to Leto as an X-task for
// ratification. `version` is the migration hook: a ratified shape lands
// additively, and an UNKNOWN version is refused rather than mis-read.
//
// HONESTY (AGENTS §11):
//   · a correction that no longer matches a note is SKIPPED and REPORTED —
//     never silently applied to the wrong note;
//   · a correction that forces two notes to overlap is REPAIRED to C-2.3 V8
//     and the repair is reported;
//   · the resolver reports which notes the USER changed, so the UI can mark
//     them as the user's opinion rather than the engine's.

// MARK: - Note identity

/// Millisecond rounding for note times (the identity's resolution).
public enum NoteIdentityMath {
    public static func ms(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }
    public static func seconds(_ milliseconds: Int) -> Double { Double(milliseconds) / 1000.0 }
}

/// A note's identity: WHERE it is and WHAT pitch — NOT which part sings it.
///
/// Millisecond resolution (not raw seconds) so the identity survives a JSON
/// round-trip without floating-point drift and stays readable by a human.
/// The PART is deliberately NOT part of the identity: a note that the user
/// MOVED to another part keeps its identity, so the "you corrected this"
/// marker follows the note into its new part.
public struct NoteIdentity: Codable, Equatable, Hashable, Sendable {
    public var start_ms: Int
    public var end_ms: Int
    public var midi: Int

    public init(start_ms: Int, end_ms: Int, midi: Int) {
        self.start_ms = start_ms
        self.end_ms = end_ms
        self.midi = midi
    }

    /// The identity of a note.
    public init(note: Note) {
        self.init(start_ms: NoteIdentityMath.ms(note.start_s),
                  end_ms: NoteIdentityMath.ms(note.end_s),
                  midi: note.midi)
    }

    public func matches(_ note: Note) -> Bool { self == NoteIdentity(note: note) }
}

/// A note's identity PLUS the part it was in when the correction was made.
public struct NoteKey: Codable, Equatable, Hashable, Sendable {
    public var part: Part
    public var identity: NoteIdentity

    public init(part: Part, identity: NoteIdentity) {
        self.part = part
        self.identity = identity
    }

    public init(part: Part, note: Note) {
        self.init(part: part, identity: NoteIdentity(note: note))
    }
}

// MARK: - The operations

/// One user correction.
///
/// The JSON shape is FLAT and hand-writable (the exact shape is proposed to
/// Leto in the X-task):
/// ```json
/// { "op": "move",   "part": "T1", "start_ms": 12000, "end_ms": 12500, "midi": 60, "toPart": "T2" }
/// { "op": "delete", "part": "T2", "start_ms": 30000, "end_ms": 30500, "midi": 62 }
/// { "op": "split",  "part": "BASS", "start_ms": 40000, "end_ms": 41000, "midi": 43, "at_ms": 40500 }
/// ```
public enum CorrectionOp: Codable, Equatable, Sendable {

    /// Move a note to another part ("this is T2, not T1").
    case move(NoteKey, toPart: Part)
    /// Delete a note ("this is not a note").
    case delete(NoteKey)
    /// Split a note in two at `at_ms` ("this is two notes").
    case split(NoteKey, at_ms: Int)

    /// The note the operation refers to.
    public var key: NoteKey {
        switch self {
        case let .move(key, _): return key
        case let .delete(key): return key
        case let .split(key, _): return key
        }
    }

    /// A one-line, human-readable description (the corrections list).
    public var summary: String {
        let part = key.part.displayName
        let at = String(format: "%.1f s", NoteIdentityMath.seconds(key.identity.start_ms))
        switch self {
        case let .move(key, toPart):
            return "Moved a \(part) note at \(at) to \(toPart.displayName)"
        case let .delete(key):
            return "Deleted a \(part) note at \(at)"
        case let .split(key, at_ms):
            return "Split a \(part) note at \(at) into two at \(String(format: "%.1f s", NoteIdentityMath.seconds(at_ms)))"
        }
    }

    // MARK: Codable (flat shape — written by hand, not synthesized)

    private enum CodingKeys: String, CodingKey {
        case op, part, start_ms, end_ms, midi, toPart, at_ms
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let key = self.key
        switch self {
        case let .move(_, toPart):
            try container.encode("move", forKey: .op)
            try encode(key, into: &container)
            try container.encode(toPart.rawValue, forKey: .toPart)
        case .delete:
            try container.encode("delete", forKey: .op)
            try encode(key, into: &container)
        case let .split(_, at_ms):
            try container.encode("split", forKey: .op)
            try encode(key, into: &container)
            try container.encode(at_ms, forKey: .at_ms)
        }
    }

    private func encode(_ key: NoteKey, into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encode(key.part.rawValue, forKey: .part)
        try container.encode(key.identity.start_ms, forKey: .start_ms)
        try container.encode(key.identity.end_ms, forKey: .end_ms)
        try container.encode(key.identity.midi, forKey: .midi)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .op)
        let part = try container.decode(Part.self, forKey: .part)
        let identity = NoteIdentity(
            start_ms: try container.decode(Int.self, forKey: .start_ms),
            end_ms: try container.decode(Int.self, forKey: .end_ms),
            midi: try container.decode(Int.self, forKey: .midi))
        let key = NoteKey(part: part, identity: identity)
        switch kind {
        case "move":
            self = .move(key, toPart: try container.decode(Part.self, forKey: .toPart))
        case "delete":
            self = .delete(key)
        case "split":
            self = .split(key, at_ms: try container.decode(Int.self, forKey: .at_ms))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .op, in: container,
                debugDescription: "Unknown correction operation '\(kind)'.")
        }
    }
}

// MARK: - The overlay

/// One song's user corrections. Additive over the engine's tracks; the raw
/// tracks on disk are never touched.
public struct CorrectionOverlay: Codable, Equatable, Sendable {

    /// The schema version. Bumped only additively; an unknown version is
    /// refused by `CorrectionStore` rather than mis-read.
    public static let currentVersion = 1

    public var version: Int
    /// The bundle this overlay belongs to (the manifest id).
    public var bundleID: String
    public var updatedAt: Date
    /// Per-song part display names — UI-only (the C-1 raw values stay the
    /// contract). Keyed by `Part.rawValue`.
    public var partRenames: [String: String]
    /// Per-song range overrides (C-6.1 preset + optional nudge, or a custom
    /// range). Keyed by `Part.rawValue`.
    public var rangeOverrides: [String: PartRangeOverride]
    /// The note corrections, applied IN ORDER.
    public var ops: [CorrectionOp]

    public init(bundleID: String,
                version: Int = CorrectionOverlay.currentVersion,
                updatedAt: Date = Date(),
                partRenames: [String: String] = [:],
                rangeOverrides: [String: PartRangeOverride] = [:],
                ops: [CorrectionOp] = []) {
        self.version = version
        self.bundleID = bundleID
        self.updatedAt = updatedAt
        self.partRenames = partRenames
        self.rangeOverrides = rangeOverrides
        self.ops = ops
    }

    /// An empty overlay (no corrections).
    public static func empty(bundleID: String) -> CorrectionOverlay {
        CorrectionOverlay(bundleID: bundleID)
    }

    /// True when the overlay changes nothing.
    public var isEmpty: Bool {
        ops.isEmpty && partRenames.isEmpty && rangeOverrides.isEmpty
    }

    /// How many note corrections are applied.
    public var correctionCount: Int { ops.count }

    // MARK: Editing (every edit is append-only or an exact reversal)

    /// Appends a note correction.
    public mutating func append(_ op: CorrectionOp) {
        ops.append(op)
        updatedAt = Date()
    }

    /// Removes the LAST correction — an exact undo, because the operations
    /// are applied in order.
    public mutating func undoLast() {
        guard !ops.isEmpty else { return }
        ops.removeLast()
        updatedAt = Date()
    }

    /// Drops every note correction (the part names and ranges stay).
    public mutating func clearNoteOps() {
        guard !ops.isEmpty else { return }
        ops.removeAll()
        updatedAt = Date()
    }

    /// Drops EVERYTHING — the overlay returns to "the engine's output, exactly".
    public mutating func resetAll() {
        ops.removeAll()
        partRenames.removeAll()
        rangeOverrides.removeAll()
        updatedAt = Date()
    }

    /// Renames a part for this song (an empty name clears the rename).
    public mutating func rename(part: Part, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            partRenames.removeValue(forKey: part.rawValue)
        } else {
            partRenames[part.rawValue] = trimmed
        }
        updatedAt = Date()
    }

    /// Sets (or clears) a part's per-song range override.
    public mutating func setRange(_ override: PartRangeOverride?, for part: Part) {
        if let override {
            rangeOverrides[part.rawValue] = override
        } else {
            rangeOverrides.removeValue(forKey: part.rawValue)
        }
        updatedAt = Date()
    }

    /// The display name for a part (the user's rename, else the contract name).
    public func displayName(for part: Part) -> String {
        let renamed = partRenames[part.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return renamed.isEmpty ? part.displayName : renamed
    }

    /// The range override for a part (nil = the C-6.1 preset).
    public func rangeOverride(for part: Part) -> PartRangeOverride? {
        rangeOverrides[part.rawValue]
    }

    /// The renames as a `[Part: String]` map (the raw values are the keys in
    /// the stored JSON, so this is the typed view of them).
    public func partNameMap() -> [Part: String] {
        var map: [Part: String] = [:]
        for (raw, name) in partRenames {
            if let part = Part(rawValue: raw) { map[part] = name }
        }
        return map
    }
}

// MARK: - The resolver (corrected-first)

/// The result of applying an overlay to the engine's tracks.
public struct EffectiveTracks: Equatable, Sendable {
    /// The corrected tracks — what every consumer (grading included) reads.
    public let tracks: [Part: NoteTrack]
    /// The notes the USER changed (moved, deleted or split) — the UI marks
    /// them so a user's opinion never looks like the engine's output.
    public let correctedIdentities: Set<NoteIdentity>
    /// Where a moved note came from (its original part).
    public let movedFrom: [NoteIdentity: Part]
    /// Everything that was skipped or repaired (never silent).
    public let warnings: [String]
    /// How many corrections were applied.
    public let appliedOpCount: Int
    /// How many corrections could not be applied (the note was gone).
    public let skippedOpCount: Int

    public init(tracks: [Part: NoteTrack],
                correctedIdentities: Set<NoteIdentity>,
                movedFrom: [NoteIdentity: Part],
                warnings: [String],
                appliedOpCount: Int,
                skippedOpCount: Int) {
        self.tracks = tracks
        self.correctedIdentities = correctedIdentities
        self.movedFrom = movedFrom
        self.warnings = warnings
        self.appliedOpCount = appliedOpCount
        self.skippedOpCount = skippedOpCount
    }

    /// True when the user changed something.
    public var hasCorrections: Bool { !correctedIdentities.isEmpty }
}

/// Applies a `CorrectionOverlay` to the engine's tracks.
///
/// THIS IS THE CORRECTED-FIRST ENTRY POINT (D-41 §4). Grading, export and
/// the piano roll all read `EffectiveTracks.tracks`, never the raw file.
public enum CorrectionResolver {

    /// Applies the overlay's operations, in order, to the raw tracks.
    public static func resolve(raw: [Part: NoteTrack],
                               overlay: CorrectionOverlay) -> EffectiveTracks {
        var working: [Part: [Note]] = [:]
        var contractVersions: [Part: String] = [:]
        for (part, track) in raw {
            working[part] = track.notes
            contractVersions[part] = track.contractVersion
        }

        var corrected = Set<NoteIdentity>()
        var movedFrom: [NoteIdentity: Part] = [:]
        var warnings: [String] = []
        var applied = 0
        var skipped = 0

        for op in overlay.ops {
            switch op {
            case let .move(key, toPart):
                var notes = working[key.part] ?? []
                guard let index = indexOf(key.identity, in: notes) else {
                    skipped += 1
                    warnings.append("A correction moved a \(key.part.displayName) note that is no longer there; it was skipped.")
                    continue
                }
                let note = notes.remove(at: index)
                working[key.part] = notes
                working[toPart, default: []].append(note)
                corrected.insert(key.identity)
                movedFrom[key.identity] = key.part
                applied += 1

            case let .delete(key):
                var notes = working[key.part] ?? []
                guard let index = indexOf(key.identity, in: notes) else {
                    skipped += 1
                    warnings.append("A correction deleted a \(key.part.displayName) note that is no longer there; it was skipped.")
                    continue
                }
                notes.remove(at: index)
                working[key.part] = notes
                corrected.insert(key.identity)
                applied += 1

            case let .split(key, at_ms):
                var notes = working[key.part] ?? []
                guard let index = indexOf(key.identity, in: notes) else {
                    skipped += 1
                    warnings.append("A correction split a \(key.part.displayName) note that is no longer there; it was skipped.")
                    continue
                }
                let note = notes[index]
                let at = NoteIdentityMath.seconds(at_ms)
                guard at > note.start_s, at < note.end_s else {
                    skipped += 1
                    warnings.append("A correction tried to split a \(key.part.displayName) note outside the note itself; it was skipped.")
                    continue
                }
                let first = Note(start_s: note.start_s, end_s: at, midi: note.midi,
                                 cents_ref: note.cents_ref, confidence: note.confidence)
                let second = Note(start_s: at, end_s: note.end_s, midi: note.midi,
                                  cents_ref: note.cents_ref, confidence: note.confidence)
                notes.remove(at: index)
                notes.append(first)
                notes.append(second)
                working[key.part] = notes
                corrected.insert(NoteIdentity(note: first))
                corrected.insert(NoteIdentity(note: second))
                applied += 1
            }
        }

        // V8: sorted by start_s, non-overlapping within a part. A move can
        // push a note on top of another one — the repair is reported.
        var tracks: [Part: NoteTrack] = [:]
        for (part, notes) in working {
            let outcome = NoteTrackRepair.repair(notes)
            if outcome.trimmedCount > 0 {
                warnings.append("Trimmed \(outcome.trimmedCount) overlapping note(s) in \(part.displayName) so the track satisfies C-2.3 V8.")
            }
            if outcome.droppedCount > 0 {
                warnings.append("Dropped \(outcome.droppedCount) note(s) in \(part.displayName) that start at the same instant as the previous note.")
            }
            tracks[part] = NoteTrack(
                contractVersion: contractVersions[part] ?? NoteTrack.currentContractVersion,
                part: part,
                notes: outcome.notes)
        }

        return EffectiveTracks(tracks: tracks,
                               correctedIdentities: corrected,
                               movedFrom: movedFrom,
                               warnings: warnings,
                               appliedOpCount: applied,
                               skippedOpCount: skipped)
    }

    /// The corrected track for ONE part (the same resolver, narrowed).
    public static func effectiveTrack(for part: Part,
                                      raw: [Part: NoteTrack],
                                      overlay: CorrectionOverlay) -> NoteTrack? {
        resolve(raw: raw, overlay: overlay).tracks[part]
    }

    /// The index of the note with this identity, or nil.
    private static func indexOf(_ identity: NoteIdentity, in notes: [Note]) -> Int? {
        notes.firstIndex { identity.matches($0) }
    }
}

// MARK: - The V8 repair (shared with the UltraStar codec)

/// Sorts a part's notes and makes them non-overlapping (C-2.3 V8).
///
/// The UltraStar importer repairs the same way; both paths use THIS one
/// implementation so "non-overlapping" means exactly one thing in the app.
public enum NoteTrackRepair {

    /// The repaired notes plus what had to change.
    public struct Outcome: Equatable, Sendable {
        public let notes: [Note]
        /// Notes whose END was trimmed (they overlapped the next note).
        public let trimmedCount: Int
        /// Notes dropped (they started at the same instant as the previous one).
        public let droppedCount: Int
    }

    /// Sorts by (start, end, pitch) and trims overlaps.
    public static func repair(_ notes: [Note]) -> Outcome {
        var sorted = notes
        sorted.sort { lhs, rhs in
            if lhs.start_s != rhs.start_s { return lhs.start_s < rhs.start_s }
            if lhs.end_s != rhs.end_s { return lhs.end_s < rhs.end_s }
            return lhs.midi < rhs.midi
        }

        var result: [Note] = []
        var trimmed = 0
        var dropped = 0
        for note in sorted {
            if let last = result.last, note.start_s < last.end_s {
                let cut = Note(start_s: last.start_s, end_s: note.start_s, midi: last.midi,
                               cents_ref: last.cents_ref, confidence: last.confidence)
                if cut.end_s > cut.start_s {
                    result[result.count - 1] = cut
                    trimmed += 1
                } else {
                    dropped += 1
                    continue
                }
            }
            result.append(note)
        }
        return Outcome(notes: result, trimmedCount: trimmed, droppedCount: dropped)
    }
}
