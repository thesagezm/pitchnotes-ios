import Foundation
import EngineCore

// CorrectionOverlay (J-302) — the USER's corrections to the engine's note
// tracks, as an ADDITIVE and REVERSIBLE layer.
//
// CONTRACTS v1.1 · C-11 (RATIFIED — L-301, D-44). THIS FILE FOLLOWS THE
// CONTRACT; IT DOES NOT INVENT A SHAPE. The four rules that decide everything:
//
//   1. THE HEURISTIC TRACK IS NEVER MUTATED IN PLACE. The engine's
//      `notes/<PART>.json` stays exactly as the engine wrote it — it is the
//      reproducible truth about what the engine heard. We NEVER write to it.
//
//   2. THE OVERLAY IS A SEPARATE, ADDITIVE FILE, stored BESIDE the bundle's
//      notes as `corrections/<PART>.json` — ONE FILE PER CORRECTED PART. A
//      part with no corrections has NO file: absence means "no corrections",
//      never "unknown".
//
//   3. THE OVERLAY WINS AT GRADING TIME (D-41 §4 / C-14 rule 1). Every
//      consumer reads the corrected tracks through `CorrectionResolver.resolve`,
//      never the raw file.
//
//   4. A CORRECTION DOES NOT ERASE THE ENGINE'S DOUBT. A corrected note keeps
//      the engine's `confidence`, and the UI still shows it as USER-CORRECTED.
//
// THE EXACT JSON (C-11 verbatim):
//
//   { "contractVersion": "v1.1", "part": "T2", "engineVersion": "corrections-0.1.0",
//     "operations": [
//       { "op": "reassign", "fromPart": "T2", "noteIndex": 3, "midi": 62 },
//       { "op": "delete",   "fromPart": "T2", "noteIndex": 7 },
//       { "op": "split",    "fromPart": "T2", "noteIndex": 9,
//         "splitAt_s": 2.5, "toParts": ["T1", "T2"] } ] }
//
// `noteIndex` is the index into the engine's ORIGINAL, IMMUTABLE `notes[]`
// array for `fromPart` (0-based, the order the engine wrote) — deliberately an
// index, so an overlay stays meaningful even as the consumer re-derives the
// track.
//
// HONESTY (AGENTS §11):
//   · an operation that no longer matches a note is SKIPPED and REPORTED —
//     never silently applied to the wrong note;
//   · an operation that forces two notes to overlap is REPAIRED to C-2.3 V8
//     and the repair is reported;
//   · the resolver reports which notes the USER changed, so the UI can mark
//     them as the user's opinion rather than the engine's.

// MARK: - Note identity (a UI-side marker, NOT a contract type)

/// Millisecond rounding for note times (the identity's resolution).
public enum NoteIdentityMath {
    public static func ms(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }
    public static func seconds(_ milliseconds: Int) -> Double { Double(milliseconds) / 1000.0 }
}

/// A note's identity: WHERE it is and WHAT pitch.
///
/// This is a DISPLAY marker (the roll marks the notes the user touched), not a
/// contract type: C-11 refers to notes by their index in the engine's original
/// array, so nothing in the stored JSON depends on this.
/// Millisecond resolution (not raw seconds) so the identity survives a JSON
/// round-trip without floating-point drift and stays readable by a human.
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

/// A note's identity PLUS the part it is in NOW (after any correction).
///
/// A note the user MOVED to another part keeps its identity and follows the
/// note into its new part, so the "you corrected this" marker is always about
/// the note, never about where it happens to sit.
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

/// Where a live note came from: the engine's original track and the index it
/// had there. This is how the UI turns a note it is displaying back into the
/// C-11 `noteIndex` the contract needs.
public struct NoteOrigin: Codable, Equatable, Hashable, Sendable {
    public var part: Part
    public var index: Int

    public init(part: Part, index: Int) {
        self.part = part
        self.index = index
    }
}

// MARK: - The operations (C-11)

/// The three operation kinds C-11 defines. The raw values are contractual.
public enum CorrectionOperationKind: String, Codable, Equatable, Sendable {
    case reassign
    case delete
    case split
}

/// One user correction — C-11's `operations[]` entry.
///
/// The JSON is FLAT and hand-written (not synthesized) so it matches the
/// contract's shape EXACTLY, including which keys are present per kind:
/// a `reassign` carries `toPart` (+ OPTIONAL `midi`), a `delete` carries
/// nothing else, a `split` carries `splitAt_s` + `toParts` (+ OPTIONAL
/// `confidence` override, proposed in X-216 and pending Leto's ruling).
public struct CorrectionOperation: Codable, Equatable, Sendable {

    /// Which operation this is.
    public var kind: CorrectionOperationKind
    /// The part whose ORIGINAL `notes[]` array holds the target note.
    public var fromPart: Part
    /// The index into that original array (0-based).
    public var noteIndex: Int
    /// `reassign`: the part the note moves to.
    public var toPart: Part?
    /// `reassign` (OPTIONAL): the corrected pitch.
    public var midi: Int?
    /// `split`: the time strictly inside the note where it is cut.
    public var splitAt_s: Double?
    /// `split`: the TWO parts the halves go to (first half → first part).
    public var toParts: [Part]?
    /// `split` (OPTIONAL): the confidence the halves carry.
    public var confidence: Double?

    public init(kind: CorrectionOperationKind,
                fromPart: Part,
                noteIndex: Int,
                toPart: Part? = nil,
                midi: Int? = nil,
                splitAt_s: Double? = nil,
                toParts: [Part]? = nil,
                confidence: Double? = nil) {
        self.kind = kind
        self.fromPart = fromPart
        self.noteIndex = noteIndex
        self.toPart = toPart
        self.midi = midi
        self.splitAt_s = splitAt_s
        self.toParts = toParts
        self.confidence = confidence
    }

    /// "This note belongs to another part" (C-11 `reassign`).
    public static func reassign(fromPart: Part, noteIndex: Int,
                                toPart: Part, midi: Int? = nil) -> CorrectionOperation {
        CorrectionOperation(kind: .reassign, fromPart: fromPart, noteIndex: noteIndex,
                            toPart: toPart, midi: midi)
    }

    /// "This is not a note" (C-11 `delete`).
    public static func delete(fromPart: Part, noteIndex: Int) -> CorrectionOperation {
        CorrectionOperation(kind: .delete, fromPart: fromPart, noteIndex: noteIndex)
    }

    /// "This is two notes" (C-11 `split`).
    public static func split(fromPart: Part, noteIndex: Int, splitAt_s: Double,
                             toParts: [Part], confidence: Double? = nil) -> CorrectionOperation {
        CorrectionOperation(kind: .split, fromPart: fromPart, noteIndex: noteIndex,
                            splitAt_s: splitAt_s, toParts: toParts, confidence: confidence)
    }

    /// A one-line, human-readable description (the corrections list).
    public var summary: String {
        switch kind {
        case .reassign:
            guard let toPart else { return "Reassigned a \(fromPart.displayName) note" }
            let pitch = midi.map { " to MIDI \($0)" } ?? ""
            return "Moved a \(fromPart.displayName) note to \(toPart.displayName)\(pitch)"
        case .delete:
            return "Deleted a \(fromPart.displayName) note"
        case .split:
            let targets = (toParts ?? []).map(\.displayName).joined(separator: " and ")
            return "Split a \(fromPart.displayName) note into \(targets.isEmpty ? "two notes" : targets)"
        }
    }

    // MARK: Codable (flat shape — written by hand, not synthesized)

    private enum CodingKeys: String, CodingKey {
        case op, fromPart, noteIndex, toPart, midi, splitAt_s, toParts, confidence
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .op)
        try container.encode(fromPart.rawValue, forKey: .fromPart)
        try container.encode(noteIndex, forKey: .noteIndex)
        switch kind {
        case .reassign:
            guard let toPart else {
                throw EncodingError.invalidValue(
                    self,
                    EncodingError.Context(codingPath: encoder.codingPath,
                                          debugDescription: "A 'reassign' operation needs a 'toPart'."))
            }
            try container.encode(toPart.rawValue, forKey: .toPart)
            if let midi {
                try container.encode(midi, forKey: .midi)
            }
        case .delete:
            break
        case .split:
            guard let splitAt_s else {
                throw EncodingError.invalidValue(
                    self,
                    EncodingError.Context(codingPath: encoder.codingPath,
                                          debugDescription: "A 'split' operation needs a 'splitAt_s'."))
            }
            guard let toParts, toParts.count == 2 else {
                throw EncodingError.invalidValue(
                    self,
                    EncodingError.Context(codingPath: encoder.codingPath,
                                          debugDescription: "A 'split' operation needs exactly two 'toParts'."))
            }
            try container.encode(splitAt_s, forKey: .splitAt_s)
            try container.encode(toParts.map(\.rawValue), forKey: .toParts)
            if let confidence {
                try container.encode(confidence, forKey: .confidence)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kindString = try container.decode(String.self, forKey: .op)
        guard let kind = CorrectionOperationKind(rawValue: kindString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .op, in: container,
                debugDescription: "Unknown correction operation '\(kindString)'.")
        }
        let fromPart = try container.decode(Part.self, forKey: .fromPart)
        let noteIndex = try container.decode(Int.self, forKey: .noteIndex)
        switch kind {
        case .reassign:
            self.init(kind: .reassign,
                      fromPart: fromPart,
                      noteIndex: noteIndex,
                      toPart: try container.decode(Part.self, forKey: .toPart),
                      midi: try container.decodeIfPresent(Int.self, forKey: .midi))
        case .delete:
            self.init(kind: .delete, fromPart: fromPart, noteIndex: noteIndex)
        case .split:
            let parts = try container.decode([Part].self, forKey: .toParts)
            guard parts.count == 2 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .toParts, in: container,
                    debugDescription: "A 'split' operation needs exactly two 'toParts' (got \(parts.count)).")
            }
            self.init(kind: .split,
                      fromPart: fromPart,
                      noteIndex: noteIndex,
                      splitAt_s: try container.decode(Double.self, forKey: .splitAt_s),
                      toParts: parts,
                      confidence: try container.decodeIfPresent(Double.self, forKey: .confidence))
        }
    }
}

// MARK: - The per-part overlay file (C-11)

/// `corrections/<PART>.json` — C-11's overlay file for ONE part.
///
/// The file describes the corrections that ORIGINATE in this part. A part with
/// no corrections has NO file (absence = "no corrections").
public struct PartCorrectionOverlay: Codable, Equatable, Sendable {

    /// C-11's contract version. A file with any other version is REFUSED
    /// (never mis-read).
    public static let contractVersion = "v1.1"

    /// The writer of the overlay (Jess's UI). C-11's own example value.
    public static let writerEngineVersion = "corrections-0.1.0"

    public var contractVersion: String
    /// The C-1 rawValue of the part this overlay describes.
    public var part: Part
    /// OPTIONAL — the writer of the overlay. Absent ⇒ "unknown".
    public var engineVersion: String?
    /// The corrections, applied IN ORDER.
    public var operations: [CorrectionOperation]

    public init(part: Part,
                engineVersion: String? = PartCorrectionOverlay.writerEngineVersion,
                operations: [CorrectionOperation] = []) {
        self.contractVersion = PartCorrectionOverlay.contractVersion
        self.part = part
        self.engineVersion = engineVersion
        self.operations = operations
    }

    /// True when this overlay changes nothing.
    public var isEmpty: Bool { operations.isEmpty }

    /// The JSON keys, spelled out so the file's shape is pinned by the code.
    private enum CodingKeys: String, CodingKey {
        case contractVersion, part, engineVersion, operations
    }
}

// MARK: - The per-song calibration overlay (C-15 — RULED at D-47)

// THE RENAME + THE RANGE OVERRIDE HAVE NO HOME IN C-11 (it covers note
// operations only, one file per corrected part). C-15 (D-47 §2) gives them a
// sibling file `corrections/song.json` inside the same bundle directory,
// with the EXACT JSON below.
//
//   { "contractVersion": "v1.1", "engineVersion": "corrections-0.1.0",
//     "partRenames": { "T1": "Tenor 1" },
//     "rangeOverrides": {
//       "T1": { "preset": "G3–E5" },
//       "BASS": { "custom": { "minMidi": 40, "maxMidi": 60 } } } }
//
// THE ABSENCE RULE (the same binding rule as C-10): absent file ⇒ no
// renames and no range overrides ⇒ the consumer behaves EXACTLY as it does
// today. The C-6.1 contract table is NEVER mutated — an override extends it
// additively.
//
// TWO THINGS THIS FILE DOES NOT CARRY (C-15 rule 2):
//   · the ±2 semitone nudge — it is DEVICE-LOCAL (C-6.1, UX §3.6) and lives
//     in `DeviceCalibration`; a writer MUST NOT write it here and a reader
//     MUST ignore it;
//   · a second preset vocabulary — the stored label is DISPLAY-ONLY and the
//     bounds always come from C-6.1's row for that part (D-47 §3).

/// The per-song calibration: the user's part renames and range overrides.
public struct SongCalibrationOverlay: Codable, Equatable, Sendable {

    public static let contractVersion = "v1.1"
    public static let writerEngineVersion = "corrections-0.1.0"

    public var contractVersion: String
    /// OPTIONAL — the writer of the overlay.
    public var engineVersion: String?
    /// Per-song part display names — UI-only (the C-1 raw values stay the
    /// contract). Keyed by `Part.rawValue`.
    public var partRenames: [String: String]
    /// Per-song range overrides. Keyed by `Part.rawValue`.
    public var rangeOverrides: [String: PartRangeOverride]

    public init(engineVersion: String? = SongCalibrationOverlay.writerEngineVersion,
                partRenames: [String: String] = [:],
                rangeOverrides: [String: PartRangeOverride] = [:]) {
        self.contractVersion = SongCalibrationOverlay.contractVersion
        self.engineVersion = engineVersion
        self.partRenames = partRenames
        self.rangeOverrides = rangeOverrides
    }

    /// True when this overlay changes nothing.
    public var isEmpty: Bool { partRenames.isEmpty && rangeOverrides.isEmpty }

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

    // The range overrides are keyed by the part's raw value, and each override
    // needs to know ITS part (the preset it was made from). So the whole file
    // is hand-decoded: the dictionary KEY supplies the part.

    private enum CodingKeys: String, CodingKey {
        case contractVersion, engineVersion, partRenames, rangeOverrides
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = try container.decode(String.self, forKey: .contractVersion)
        engineVersion = try container.decodeIfPresent(String.self, forKey: .engineVersion)
        partRenames = try container.decodeIfPresent([String: String].self, forKey: .partRenames) ?? [:]
        let stored = try container.decodeIfPresent([String: StoredPartRangeOverride].self,
                                                   forKey: .rangeOverrides) ?? [:]
        var overrides: [String: PartRangeOverride] = [:]
        for (raw, value) in stored {
            guard let part = Part(rawValue: raw) else { continue }
            overrides[raw] = value.makeOverride(for: part)
        }
        rangeOverrides = overrides
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contractVersion, forKey: .contractVersion)
        try container.encodeIfPresent(engineVersion, forKey: .engineVersion)
        try container.encode(partRenames, forKey: .partRenames)
        var stored: [String: StoredPartRangeOverride] = [:]
        for (raw, override) in rangeOverrides {
            stored[raw] = override.storedForm()
        }
        try container.encode(stored, forKey: .rangeOverrides)
    }
}

// MARK: - The V8 repair (shared with the UltraStar codec)

/// A live note: the note itself plus where it came from (the engine's
/// original part + index). The overlay's `noteIndex` addresses THIS origin.
struct LiveNote: Equatable {
    var note: Note
    var origin: NoteOrigin
}

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
        // The origins are irrelevant here; the repair is the SAME code path,
        // so "non-overlapping" means exactly one thing in the app.
        let pieces = notes.map { LiveNote(note: $0, origin: NoteOrigin(part: .t1, index: 0)) }
        let result = repairKeepingOrigins(pieces)
        return Outcome(notes: result.notes.map(\.note),
                       trimmedCount: result.trimmedCount,
                       droppedCount: result.droppedCount)
    }

    /// The same repair, keeping each note's ORIGIN attached — the overlay
    /// needs it (a trimmed note must still be addressable by the index the
    /// contract used).
    static func repairKeepingOrigins(
        _ pieces: [LiveNote]
    ) -> (notes: [LiveNote], trimmedCount: Int, droppedCount: Int) {
        var sorted = pieces
        sorted.sort { lhs, rhs in
            if lhs.note.start_s != rhs.note.start_s { return lhs.note.start_s < rhs.note.start_s }
            if lhs.note.end_s != rhs.note.end_s { return lhs.note.end_s < rhs.note.end_s }
            return lhs.note.midi < rhs.note.midi
        }

        var result: [LiveNote] = []
        var trimmed = 0
        var dropped = 0
        for piece in sorted {
            if let last = result.last, piece.note.start_s < last.note.end_s {
                let cut = Note(start_s: last.note.start_s, end_s: piece.note.start_s,
                               midi: last.note.midi, cents_ref: last.note.cents_ref,
                               confidence: last.note.confidence)
                if cut.end_s > cut.start_s {
                    result[result.count - 1] = LiveNote(note: cut, origin: last.origin)
                    trimmed += 1
                } else {
                    dropped += 1
                    continue
                }
            }
            result.append(piece)
        }
        return (notes: result, trimmedCount: trimmed, droppedCount: dropped)
    }
}

// MARK: - The resolver (corrected-first)

/// The result of applying the overlays to the engine's tracks.
public struct EffectiveTracks: Equatable, Sendable {
    /// The corrected tracks — what every consumer (grading included) reads.
    public let tracks: [Part: NoteTrack]
    /// The notes the USER changed (reassigned or split) — the UI marks them
    /// so a user's opinion never looks like the engine's output. A DELETED
    /// note has nothing left to mark.
    public let correctedNotes: Set<NoteKey>
    /// Where each surviving note came from — the engine's original part and
    /// index. This is how the UI turns a note it is SHOWING back into the
    /// C-11 `noteIndex` the contract needs.
    public let origins: [NoteKey: NoteOrigin]
    /// Everything that was skipped or repaired (never silent).
    public let warnings: [String]
    /// How many corrections were applied.
    public let appliedOpCount: Int
    /// How many corrections could not be applied (the note was gone, or the
    /// operation broke C-11's own rules).
    public let skippedOpCount: Int

    public init(tracks: [Part: NoteTrack],
                correctedNotes: Set<NoteKey>,
                origins: [NoteKey: NoteOrigin],
                warnings: [String],
                appliedOpCount: Int,
                skippedOpCount: Int) {
        self.tracks = tracks
        self.correctedNotes = correctedNotes
        self.origins = origins
        self.warnings = warnings
        self.appliedOpCount = appliedOpCount
        self.skippedOpCount = skippedOpCount
    }

    /// The origin of a note the roll is displaying (nil when the note has no
    /// engine origin — it cannot be corrected by index then).
    public func origin(for key: NoteKey) -> NoteOrigin? { origins[key] }

    /// True when the user changed something.
    public var hasCorrections: Bool { !correctedNotes.isEmpty }
}

/// Applies the correction overlays to the engine's tracks.
///
/// THIS IS THE CORRECTED-FIRST ENTRY POINT (D-41 §4 / C-14 rule 1). Grading,
/// export and the piano roll all read `EffectiveTracks.tracks`, never the raw
/// file.
///
/// THE OPERATIONS ARE APPLIED IN ORDER (C-11). Each operation refers to a note
/// by its index in the engine's ORIGINAL, IMMUTABLE `notes[]` array for
/// `fromPart`, so an overlay stays meaningful even as the consumer re-derives
/// the track. When one operation's target has already been changed by an
/// earlier one, the LATER operation still refers to the same ORIGINAL note and
/// acts on whatever that note has become (the rule the contract implies by
/// indexing the immutable array — documented here because the contract does
/// not spell it out):
///
///   · `reassign` — every piece of the original note moves to `toPart` (and
///     takes the optional `midi` correction);
///   · `delete` — every piece of the original note goes away;
///   · `split` — the piece that CONTAINS `splitAt_s` is cut in two; the first
///     half goes to `toParts[0]`, the second to `toParts[1]`. If no piece
///     contains it (or more than one does), the operation is SKIPPED and
///     REPORTED — never guessed at.
public enum CorrectionResolver {

    /// Applies every part's overlay, in order, to the raw tracks.
    ///
    /// - Parameters:
    ///   - raw: the engine's tracks, exactly as the engine wrote them.
    ///   - overlays: the per-part overlays (`corrections/<PART>.json`).
    public static func resolve(raw: [Part: NoteTrack],
                               overlays: [Part: PartCorrectionOverlay]) -> EffectiveTracks {
        var live: [Part: [LiveNote]] = [:]
        var contractVersions: [Part: String] = [:]
        for (part, track) in raw {
            live[part] = track.notes.enumerated().map { index, note in
                LiveNote(note: note, origin: NoteOrigin(part: part, index: index))
            }
            contractVersions[part] = track.contractVersion
        }

        var touchedOrigins = Set<NoteOrigin>()
        var warnings: [String] = []
        var applied = 0
        var skipped = 0

        // The parts are visited in C-1 order so the result is DETERMINISTIC
        // (C-11 fixes the order WITHIN a file; it says nothing about the order
        // BETWEEN files, so we pick one and keep it).
        for part in raw.keys.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            guard let overlay = overlays[part] else { continue }
            for op in overlay.operations {
                switch apply(op, to: &live, raw: raw) {
                case .applied(let origins):
                    applied += 1
                    touchedOrigins.formUnion(origins)
                case .skipped(let reason):
                    skipped += 1
                    warnings.append(reason)
                }
            }
        }

        // V8: sorted by start_s, non-overlapping within a part. A reassign can
        // push a note on top of another one — the repair is reported.
        var tracks: [Part: NoteTrack] = [:]
        var originsByKey: [NoteKey: NoteOrigin] = [:]
        var correctedAfterRepair = Set<NoteKey>()
        for part in live.keys.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let outcome = NoteTrackRepair.repairKeepingOrigins(live[part] ?? [])
            if outcome.trimmedCount > 0 {
                warnings.append("Trimmed \(outcome.trimmedCount) overlapping note(s) in \(part.displayName) so the track satisfies C-2.3 V8.")
            }
            if outcome.droppedCount > 0 {
                warnings.append("Dropped \(outcome.droppedCount) note(s) in \(part.displayName) that start at the same instant as the previous note.")
            }
            tracks[part] = NoteTrack(
                contractVersion: contractVersions[part] ?? NoteTrack.currentContractVersion,
                part: part,
                notes: outcome.notes.map(\.note))

            // The identities are taken from the REPAIRED notes, so the marker
            // the UI draws always matches the note the UI draws.
            for piece in outcome.notes {
                let key = NoteKey(part: part, note: piece.note)
                originsByKey[key] = piece.origin
                if touchedOrigins.contains(piece.origin) {
                    correctedAfterRepair.insert(key)
                }
            }
        }

        return EffectiveTracks(tracks: tracks,
                               correctedNotes: correctedAfterRepair,
                               origins: originsByKey,
                               warnings: warnings,
                               appliedOpCount: applied,
                               skippedOpCount: skipped)
    }

    /// The outcome of applying one operation.
    private enum ApplyOutcome {
        case applied(origins: Set<NoteOrigin>)
        case skipped(reason: String)
    }

    /// Applies one operation to the live notes.
    private static func apply(_ op: CorrectionOperation,
                              to live: inout [Part: [LiveNote]],
                              raw: [Part: NoteTrack]) -> ApplyOutcome {
        // The index must be inside the engine's ORIGINAL array.
        guard let original = raw[op.fromPart], original.notes.indices.contains(op.noteIndex) else {
            return .skipped(reason: "A correction pointed at note #\(op.noteIndex) in \(op.fromPart.displayName), but the engine's track has no such note; it was skipped.")
        }
        let origin = NoteOrigin(part: op.fromPart, index: op.noteIndex)
        let pieces = pieces(of: origin, in: live)
        guard !pieces.isEmpty else {
            return .skipped(reason: "A correction pointed at note #\(op.noteIndex) in \(op.fromPart.displayName), which is no longer in the corrected track; it was skipped.")
        }

        switch op.kind {
        case .reassign:
            guard let toPart = op.toPart else {
                return .skipped(reason: "A correction moved a \(op.fromPart.displayName) note but did not say where to; it was skipped.")
            }
            var moved: [Note] = []
            for piece in pieces {
                var note = piece.note
                if let midi = op.midi {
                    note.midi = midi
                }
                moved.append(note)
            }
            remove(origin, from: &live)
            for note in moved {
                live[toPart, default: []].append(LiveNote(note: note, origin: origin))
            }
            return .applied(origins: [origin])

        case .delete:
            remove(origin, from: &live)
            // A deleted note has nothing left to mark — but the correction
            // still counts as applied.
            return .applied(origins: [origin])

        case .split:
            guard let splitAt_s = op.splitAt_s else {
                return .skipped(reason: "A correction split a \(op.fromPart.displayName) note but did not say where; it was skipped.")
            }
            guard let toParts = op.toParts, toParts.count == 2 else {
                return .skipped(reason: "A correction split a \(op.fromPart.displayName) note but did not name the two parts; it was skipped.")
            }
            let inside = pieces.filter { $0.note.start_s < splitAt_s && splitAt_s < $0.note.end_s }
            guard inside.count == 1 else {
                return .skipped(reason: "A correction tried to split a \(op.fromPart.displayName) note at \(String(format: "%.3f", splitAt_s)) s, which is not strictly inside the note; it was skipped.")
            }
            let target = inside[0]
            let first = Note(start_s: target.note.start_s, end_s: splitAt_s,
                             midi: target.note.midi, cents_ref: target.note.cents_ref,
                             confidence: op.confidence ?? target.note.confidence)
            let second = Note(start_s: splitAt_s, end_s: target.note.end_s,
                              midi: target.note.midi, cents_ref: target.note.cents_ref,
                              confidence: op.confidence ?? target.note.confidence)
            remove(origin, from: &live)
            live[toParts[0], default: []].append(LiveNote(note: first, origin: origin))
            live[toParts[1], default: []].append(LiveNote(note: second, origin: origin))
            return .applied(origins: [origin])
        }
    }

    /// Every live note that descends from the given original note.
    private static func pieces(of origin: NoteOrigin,
                               in live: [Part: [LiveNote]]) -> [LiveNote] {
        var result: [LiveNote] = []
        for part in live.keys.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            for piece in live[part] ?? [] where piece.origin == origin {
                result.append(piece)
            }
        }
        return result
    }

    /// Removes every live note that descends from the given original note.
    private static func remove(_ origin: NoteOrigin, from live: inout [Part: [LiveNote]]) {
        for part in live.keys {
            live[part]?.removeAll { $0.origin == origin }
        }
    }
}
