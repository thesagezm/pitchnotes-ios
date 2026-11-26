import Foundation

// P-304 · The score contract types — THE ENGINE'S OWN COPY (C-13.1 + C-13.2).
//
// WHAT THIS IS: the shapes the engine PRODUCES and the UI CONSUMES — the
// score-note list (C-13.1) and the alignment metadata (C-13.2). The JSON is
// the contract's JSON, key for key, because the JSON is what crosses the lane
// boundary (CONTRACTS v1.1.1, C-13).
//
// WHY THE TYPES ARE NAMESPACED (`ScoreContract.Note`, NOT a top-level
// `ScoreNote`) — A MEASURED DECISION, recorded in QUEUE.md's LOG (2026-11-26):
//
//   · Jess's J-304 already declares `ScoreNote`, `ScoreNoteList`,
//     `BarMapEntry`, `ScoreAlignment`, `ScoreAlignmentFile`,
//     `ScoreAlignmentResult`, `ScoreAlignedNote`, `ScoreAgreement` and the
//     `ScoreImportService` seam in `Tests/Logic/**` — HER lane, which
//     AGENTS §12 says I may not edit;
//   · Swift resolves an unqualified name that exists in TWO imported modules
//     as an ERROR: "'X' is ambiguous for type lookup in this context" (I
//     MEASURED this — it is not a guess);
//   · BOTH `Tests/Logic/Tests/PitchLogicTests/ScoreReviewTests.swift` (imports
//     `EngineCore` + `@testable import PitchLogic`) and
//     `App/Sources/Features/Notes/ScoreReviewView.swift` (imports both) use
//     those names unqualified.
//
// ⇒ Declaring the same top-level names HERE would turn `logic-tests` AND
// `build-ipa` RED in files that are not mine to touch. So the engine's types
// live under ONE namespace and the JSON shape is identical. **The end-state
// migration is a one-line-per-type edit in Jess's lane**
// (`public typealias ScoreNote = ScoreContract.Note` …), which collapses the
// D-33 "one semantic, never two" residue to zero without touching a single
// app call site. That edit is FILED for Leto (the LOG entry), not made here.
//
// HONESTY (AGENTS §11):
//   · the score is OPTIONAL end-to-end — absent ⇒ heuristic-only;
//   · the PARSER NEVER ALIGNS BY ITSELF (D-40 §5) — parsing and alignment are
//     separate steps and only alignment produces C-13.2;
//   · `used` is a DECISION that is recorded, never assumed;
//   · the alignment's `confidence` is the ALIGNMENT's confidence. It is NOT a
//     per-note probability and it is NEVER the model's salience (C-12).

// MARK: - The namespace

/// The engine's score contract types (C-13).
public enum ScoreContract {

    // MARK: C-13.1 · The score-note list

    /// One note of the score-note list (C-13.1).
    ///
    /// JSON: `{ "midi", "start_s", "end_s", "measure", "part_id", "voice" }` —
    /// the property names ARE the JSON keys, so the synthesized `Codable`
    /// conformance is the contract's shape exactly.
    public struct Note: Codable, Equatable, Sendable {
        /// Equal-tempered MIDI note number (A440, C4 = 60).
        public var midi: Int
        /// Seconds at the score's OWN tempo, BEFORE any alignment to the audio.
        public var start_s: Double
        /// Seconds at the score's own tempo. `start_s < end_s`.
        public var end_s: Double
        /// The measure index within the score (≥ 1).
        public var measure: Int
        /// The SCORE's own part identifier (e.g. `"P1"`) — NOT a C-1 `Part`
        /// rawValue: the score does not know our part naming (C-13.1).
        public var part_id: String
        /// The voice within the part (≥ 1).
        public var voice: Int

        public init(midi: Int, start_s: Double, end_s: Double,
                    measure: Int, part_id: String, voice: Int) {
            self.midi = midi
            self.start_s = start_s
            self.end_s = end_s
            self.measure = measure
            self.part_id = part_id
            self.voice = voice
        }

        /// The note's duration in seconds.
        public var duration: Double { max(0, end_s - start_s) }
    }

    /// The score-note list (C-13.1).
    ///
    /// JSON: `{ "contractVersion": "v1.1", "scoreNotes": [...] }`.
    public struct NoteList: Codable, Equatable, Sendable {
        /// The on-disk contract version string (the v1.1 family, D-47 §10).
        public static let currentContractVersion = "v1.1"

        public var contractVersion: String
        public var scoreNotes: [Note]

        public init(contractVersion: String = NoteList.currentContractVersion,
                    scoreNotes: [Note]) {
            self.contractVersion = contractVersion
            self.scoreNotes = scoreNotes
        }

        /// The score's own duration in seconds (0 when the list is empty).
        public var duration: Double {
            scoreNotes.map(\.end_s).max() ?? 0
        }

        /// The measures the score covers, in order.
        public var measures: [Int] {
            Array(Set(scoreNotes.map(\.measure))).sorted()
        }

        /// The score's own part identifiers, in the order they first appear.
        public var partIdentifiers: [String] {
            var seen = Set<String>()
            var result: [String] = []
            for note in scoreNotes where !seen.contains(note.part_id) {
                seen.insert(note.part_id)
                result.append(note.part_id)
            }
            return result
        }
    }

    // MARK: C-13.2 · The alignment metadata

    /// One bar-map entry (C-13.2): the measure's span in AUDIO seconds.
    ///
    /// This is the bar map that turns D-41 §2's fixed 4.0 s phrases into
    /// BAR-ALIGNED phrases when a score is present.
    public struct BarMapEntry: Codable, Equatable, Sendable {
        public var measure: Int
        public var start_s: Double
        public var end_s: Double

        public init(measure: Int, start_s: Double, end_s: Double) {
            self.measure = measure
            self.start_s = start_s
            self.end_s = end_s
        }

        /// The bar's duration in seconds.
        public var duration: Double { max(0, end_s - start_s) }
    }

    /// The alignment metadata (C-13.2).
    ///
    /// JSON (inside the file's `alignment` object): `{ "confidence", "used",
    /// "barMap", "method", "partMapping" }`. `method` is OPTIONAL — absent ⇒
    /// `"unknown"`. `partMapping` is OPTIONAL — absent ⇒ NO score note is
    /// placed into any part (C-13.2 v1.1.1, D-47 §8).
    public struct Alignment: Codable, Equatable, Sendable {

        public var confidence: Double
        /// Whether this alignment was actually applied to the graded track. A
        /// consumer MUST NOT assume `used == true` — it is READ.
        public var used: Bool
        public var barMap: [BarMapEntry]
        /// Free string (e.g. `"DTW"`). Absent ⇒ `"unknown"`.
        public var method: String?
        /// The score's `part_id` → the C-1 part it was aligned to (C-13.2 v1.1.1).
        ///
        /// **OPTIONAL.** ABSENT ⇒ **no score note is placed into any part** —
        /// the honest "unmapped" state; a consumer MUST NOT guess a mapping.
        public var partMapping: [String: Part]?

        public init(confidence: Double, used: Bool, barMap: [BarMapEntry],
                    method: String? = nil, partMapping: [String: Part]? = nil) {
            self.confidence = confidence
            self.used = used
            self.barMap = barMap
            self.method = method
            self.partMapping = partMapping
        }

        /// The method name, or `"unknown"` when the field was absent (C-13.2).
        public var methodName: String { method ?? "unknown" }

        /// The bar-map entry for a measure (nil when the map does not cover it).
        public func bar(for measure: Int) -> BarMapEntry? {
            barMap.first { $0.measure == measure }
        }

        /// The bar starts, in measure order.
        public var barStarts: [Double] {
            barMap.sorted { $0.measure < $1.measure }.map(\.start_s)
        }

        // MARK: Codable (the mapping's values are C-1 rawValues)

        private enum CodingKeys: String, CodingKey {
            case confidence, used, barMap, method, partMapping
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            confidence = try container.decode(Double.self, forKey: .confidence)
            used = try container.decode(Bool.self, forKey: .used)
            barMap = try container.decodeIfPresent([BarMapEntry].self, forKey: .barMap) ?? []
            method = try container.decodeIfPresent(String.self, forKey: .method)
            // The mapping is OPTIONAL: absent ⇒ nil ⇒ no score note enters any
            // part (C-13.2 rule, D-47 §8).
            if let raw = try container.decodeIfPresent([String: String].self, forKey: .partMapping) {
                var mapping: [String: Part] = [:]
                for (partID, rawValue) in raw {
                    // A value that is not a C-1 rawValue is IGNORED, never a
                    // reason to reject the whole alignment.
                    if let part = Part(rawValue: rawValue) {
                        mapping[partID] = part
                    }
                }
                partMapping = mapping
            } else {
                partMapping = nil
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(confidence, forKey: .confidence)
            try container.encode(used, forKey: .used)
            try container.encode(barMap, forKey: .barMap)
            try container.encodeIfPresent(method, forKey: .method)
            try container.encodeIfPresent(partMapping?.mapValues(\.rawValue), forKey: .partMapping)
        }
    }

    /// The alignment FILE (C-13.2's example shape):
    /// `{ "contractVersion": "v1.1", "alignment": { ... } }`.
    public struct AlignmentFile: Codable, Equatable, Sendable {
        public static let currentContractVersion = "v1.1"

        public var contractVersion: String
        public var alignment: Alignment

        public init(contractVersion: String = AlignmentFile.currentContractVersion,
                    alignment: Alignment) {
            self.contractVersion = contractVersion
            self.alignment = alignment
        }
    }

    /// The alignment RESULT: C-13.2's metadata + the score-part → C-1-part
    /// mapping THAT IT CARRIES.
    ///
    /// **ABSENT ⇒ no score note is placed into any part**, and a consumer MUST
    /// NOT invent, infer or guess a mapping (D-47 §8).
    public struct AlignmentResult: Equatable, Sendable {
        public var alignment: Alignment
        /// The score's `part_id` → the C-1 part it was aligned to (empty when
        /// the alignment carries no mapping).
        public var partMapping: [String: Part]

        /// Builds the result from the alignment — the mapping comes FROM the
        /// alignment's JSON, never from a guess.
        public init(alignment: Alignment) {
            self.alignment = alignment
            self.partMapping = alignment.partMapping ?? [:]
        }

        /// Builds the result with an explicit mapping — the seam's escape hatch
        /// for an aligner that has not written the mapping into the JSON yet.
        /// The JSON's mapping WINS when it has one (D-47 §8).
        public init(alignment: Alignment, partMapping: [String: Part]) {
            self.alignment = alignment
            self.partMapping = alignment.partMapping ?? partMapping
        }
    }

    // MARK: - The aligned score notes

    /// One score note after it has been placed on the audio timeline.
    public struct AlignedNote: Equatable, Sendable, Identifiable {
        /// The index of this note in the score-note list (stable identity — the
        /// user's nudge is stored against it).
        public var scoreIndex: Int
        /// The C-1 part the alignment mapped it to. NIL when the score's part
        /// has no C-1 mapping — the note is still placed in time (so the
        /// agreement is honest) but it is NOT put into any part's track.
        public var part: Part?
        public var midi: Int
        /// The score's own times (at the score's tempo).
        public var scoreStart_s: Double
        public var scoreEnd_s: Double
        /// The ALIGNED time (bar-mapped), before the user's nudge.
        public var alignedStart_s: Double
        public var alignedEnd_s: Double
        /// The measure the note is in.
        public var measure: Int
        /// The score's own part identifier.
        public var scorePartID: String
        /// The voice within the score's part.
        public var voice: Int

        public var id: Int { scoreIndex }

        public init(scoreIndex: Int, part: Part?, midi: Int,
                    scoreStart_s: Double, scoreEnd_s: Double,
                    alignedStart_s: Double, alignedEnd_s: Double,
                    measure: Int, scorePartID: String, voice: Int) {
            self.scoreIndex = scoreIndex
            self.part = part
            self.midi = midi
            self.scoreStart_s = scoreStart_s
            self.scoreEnd_s = scoreEnd_s
            self.alignedStart_s = alignedStart_s
            self.alignedEnd_s = alignedEnd_s
            self.measure = measure
            self.scorePartID = scorePartID
            self.voice = voice
        }
    }

    // MARK: - The agreement (D-41 §4's "improved note agreement")

    /// How well two note sets agree (D-41 §4's second condition for using the
    /// score-informed track).
    ///
    /// THE METRIC (deterministic, documented, symmetric — the same definition
    /// Jess's `ScoreAgreement` uses, so the two sides report the same number):
    ///   · two notes MATCH when they have the SAME MIDI and their time
    ///     intervals overlap after both are extended by `tolerance_s`;
    ///   · `ratio` is the matched pairs over all pairs (a Dice-style share in
    ///     [0, 1]) — it counts BOTH directions, so a score that drops half the
    ///     song cannot look like a perfect match.
    public struct Agreement: Equatable, Sendable {
        /// The default match tolerance (seconds).
        public static let defaultTolerance_s: Double = 0.25

        public var matchedScoreNotes: Int
        public var scoreNoteCount: Int
        public var matchedDetectedNotes: Int
        public var detectedNoteCount: Int

        public init(matchedScoreNotes: Int, scoreNoteCount: Int,
                    matchedDetectedNotes: Int, detectedNoteCount: Int) {
            self.matchedScoreNotes = matchedScoreNotes
            self.scoreNoteCount = scoreNoteCount
            self.matchedDetectedNotes = matchedDetectedNotes
            self.detectedNoteCount = detectedNoteCount
        }

        /// The agreement ratio in [0, 1]. 0 when there is nothing to compare.
        public var ratio: Double {
            let total = scoreNoteCount + detectedNoteCount
            guard total > 0 else { return 0 }
            return Double(matchedScoreNotes + matchedDetectedNotes) / Double(total)
        }

        /// The agreement between a score-note list and the detected tracks.
        public static func between(score: [Note], detected: [Part: NoteTrack],
                                    tolerance_s: Double = defaultTolerance_s) -> Agreement {
            let detectedNotes = detected.values.flatMap(\.notes)
            var matchedScore = Set<Int>()
            var matchedDetected = Set<Int>()
            for (scoreIndex, scoreNote) in score.enumerated() {
                for (index, detectedNote) in detectedNotes.enumerated() {
                    guard scoreNote.midi == detectedNote.midi else { continue }
                    if overlaps(scoreNote.start_s, scoreNote.end_s,
                                detectedNote.start_s, detectedNote.end_s, tolerance: tolerance_s) {
                        matchedScore.insert(scoreIndex)
                        matchedDetected.insert(index)
                    }
                }
            }
            return Agreement(matchedScoreNotes: matchedScore.count,
                             scoreNoteCount: score.count,
                             matchedDetectedNotes: matchedDetected.count,
                             detectedNoteCount: detectedNotes.count)
        }

        /// Do the two intervals overlap once both are extended by `tolerance`?
        static func overlaps(_ aStart: Double, _ aEnd: Double,
                             _ bStart: Double, _ bEnd: Double, tolerance: Double) -> Bool {
            aStart - tolerance < bEnd && bStart - tolerance < aEnd
        }
    }
}

// MARK: - C-11 · The correction overlay (the engine's side)

extension ScoreContract {

    /// Which correction operation this is (C-11's `op`).
    public enum CorrectionOperationKind: String, Codable, Equatable, Sendable {
        case reassign
        case delete
        case split
    }

    /// One user correction — C-11's `operations[]` entry.
    ///
    /// THE JSON IS THE CONTRACT'S JSON, key for key:
    /// `{ "op", "fromPart", "noteIndex", "toPart"?, "midi"?, "splitAt_s"?,
    ///    "toParts"?, "confidence"? }`.
    ///
    /// **WHY THE ENGINE HAS ITS OWN COPY:** Jess's J-302 owns the correction
    /// OVERLAY (the storage format + the UI) in `Tests/Logic/**`; the ENGINE
    /// owns the guarantee that a correction never mutates the engine's own
    /// `notes/<PART>.json` in place and that the operations are applied IN
    /// ORDER with the engine's confidence preserved unless the operation
    /// overrides it (C-11 rules 1 + 4). The two implementations agree BY JSON
    /// (the wire format), and the end-state migration — PitchLogic delegating
    /// to this applier — is FILED for Leto (the LOG entry of 2026-11-26), the
    /// same one-line-per-type story as the score types above.
    public struct CorrectionOperation: Codable, Equatable, Sendable {

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
                if let midi { try container.encode(midi, forKey: .midi) }
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
                if let confidence { try container.encode(confidence, forKey: .confidence) }
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let rawOp = try container.decode(String.self, forKey: .op)
            guard let kind = CorrectionOperationKind(rawValue: rawOp) else {
                throw DecodingError.dataCorruptedError(forKey: .op, in: container,
                                                       debugDescription: "Unknown correction operation '\(rawOp)'.")
            }
            self.kind = kind
            fromPart = try container.decode(Part.self, forKey: .fromPart)
            noteIndex = try container.decode(Int.self, forKey: .noteIndex)
            toPart = try container.decodeIfPresent(Part.self, forKey: .toPart)
            midi = try container.decodeIfPresent(Int.self, forKey: .midi)
            splitAt_s = try container.decodeIfPresent(Double.self, forKey: .splitAt_s)
            toParts = try container.decodeIfPresent([Part].self, forKey: .toParts)
            confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        }
    }

    /// The correction overlay FILE (C-11): `corrections/<PART>.json`.
    ///
    /// JSON: `{ "contractVersion": "v1.1", "part": "T2",
    ///          "engineVersion": "corrections-0.1.0", "operations": [...] }`.
    public struct CorrectionOverlay: Codable, Equatable, Sendable {
        public static let currentContractVersion = "v1.1"

        public var contractVersion: String
        /// The C-1 rawValue of the part this overlay describes.
        public var part: Part
        /// OPTIONAL — the writer of the overlay. Absent ⇒ `"unknown"`, and the
        /// consumer MUST NOT refuse the file (C-11's absence rule).
        public var engineVersion: String?
        /// The ordered operations. **The order IS the application order.**
        public var operations: [CorrectionOperation]

        public init(contractVersion: String = CorrectionOverlay.currentContractVersion,
                    part: Part,
                    engineVersion: String? = nil,
                    operations: [CorrectionOperation]) {
            self.contractVersion = contractVersion
            self.part = part
            self.engineVersion = engineVersion
            self.operations = operations
        }

        public var isEmpty: Bool { operations.isEmpty }
    }

    /// The result of applying the corrections.
    public struct CorrectionOutcome: Equatable, Sendable {
        /// The corrected tracks (the engine's own tracks are NOT mutated).
        public var tracks: [Part: NoteTrack]
        /// The problems that were REPORTED (never silently clamped — C-11 and
        /// C-16's "a missing target is reported, never clamped" posture).
        public var problems: [String]
    }

    /// Applies C-11's correction overlay to the engine's own tracks.
    ///
    /// THE RULES (C-11, verbatim):
    /// 1. **The overlay is separate and additive; the heuristic track is NEVER
    ///    mutated in place.** The engine's `notes/<PART>.json` stays exactly
    ///    what the engine wrote — this function RETURNS a corrected copy and
    ///    touches nothing on disk.
    /// 2. **The order IS the application order** and the operations MUST be
    ///    applied in order.
    /// 3. The overlay is OPTIONAL — absent ⇒ the caller uses the engine's
    ///    tracks unchanged.
    /// 4. **A correction does not erase the engine's doubt:** a corrected note
    ///    keeps the engine's `confidence` unless the operation overrides it.
    ///
    /// A `split` whose `splitAt_s` is NOT strictly inside the note is a
    /// CONTRACT VIOLATION that is REPORTED (in `problems`) and the operation is
    /// SKIPPED — never silently clamped (D-47 §5).
    public enum CorrectionApplier {

        /// Apply the ordered operations and return the corrected tracks.
        public static func apply(_ operations: [CorrectionOperation],
                                 to tracks: [Part: NoteTrack]) -> CorrectionOutcome {
            var working: [Part: [EngineCore.Note]] = [:]
            var origins: [Part: [Int: NoteOriginIndex]] = [:]
            for (part, track) in tracks {
                working[part] = track.notes
                var map: [Int: NoteOriginIndex] = [:]
                for (index, _) in track.notes.enumerated() { map[index] = .engine(index) }
                origins[part] = map
            }
            var problems: [String] = []

            for operation in operations {
                guard let source = working[operation.fromPart] else {
                    problems.append("No track for \(operation.fromPart.rawValue) — the operation was skipped.")
                    continue
                }
                guard let origin = origins[operation.fromPart]?[operation.noteIndex] else {
                    problems.append("Note index \(operation.noteIndex) is not in \(operation.fromPart.rawValue)'s notes — the operation was skipped.")
                    continue
                }
                switch operation.kind {
                case .delete:
                    remove(origin: origin, from: operation.fromPart, working: &working)
                case .reassign:
                    guard let target = operation.toPart else {
                        problems.append("A 'reassign' without a 'toPart' was skipped.")
                        continue
                    }
                    guard let note = note(at: origin, in: source) else { continue }
                    var moved = note
                    if let midi = operation.midi { moved.midi = midi }
                    remove(origin: origin, from: operation.fromPart, working: &working)
                    working[target, default: []].append(moved)
                case .split:
                    guard let splitAt = operation.splitAt_s,
                          let parts = operation.toParts, parts.count == 2 else {
                        problems.append("A 'split' without a 'splitAt_s' and two 'toParts' was skipped.")
                        continue
                    }
                    guard let note = note(at: origin, in: source) else { continue }
                    guard splitAt > note.start_s, splitAt < note.end_s else {
                        problems.append("A 'split' at \(splitAt)s is not strictly inside the note (\(note.start_s)…\(note.end_s)s) — it was skipped, NOT clamped.")
                        continue
                    }
                    remove(origin: origin, from: operation.fromPart, working: &working)
                    // The confidence override applies to BOTH halves; absent ⇒
                    // both keep the engine's confidence (C-11 rule 4).
                    let confidence = operation.confidence ?? note.confidence
                    let first = EngineCore.Note(start_s: note.start_s, end_s: splitAt, midi: note.midi,
                                     cents_ref: note.cents_ref, confidence: confidence,
                                     unison: note.unison, salience: note.salience,
                                     assignmentBand: note.assignmentBand)
                    let second = EngineCore.Note(start_s: splitAt, end_s: note.end_s, midi: note.midi,
                                      cents_ref: note.cents_ref, confidence: confidence,
                                      unison: note.unison, salience: note.salience,
                                      assignmentBand: note.assignmentBand)
                    working[parts[0], default: []].append(first)
                    working[parts[1], default: []].append(second)
                }
            }

            var result: [Part: NoteTrack] = [:]
            for (part, notes) in working {
                result[part] = NoteTrack(contractVersion: NoteTrack.contractVersionV11,
                                         part: part,
                                         notes: repairOverlaps(notes),
                                         engineVersion: tracks[part]?.engineVersion,
                                         partPresence: tracks[part]?.partPresence,
                                         assignmentSummary: tracks[part]?.assignmentSummary)
            }
            return CorrectionOutcome(tracks: result, problems: problems)
        }

        /// C-2.3 V8: sorted by `start_s`, never overlapping within a part.
        ///
        /// The overlap is resolved by TRUNCATING THE EARLIER NOTE'S SUSTAIN at
        /// the later note's onset — the same direction and the same reasoning
        /// as `NoteTrackBuilder.repairOverlaps` (the onsets are the engine's
        /// measurement and they stay exact; the sustain is what we give up).
        /// A note swallowed entirely by the overlap is dropped (V7 forbids
        /// `start_s >= end_s`).
        static func repairOverlaps(_ notes: [EngineCore.Note]) -> [EngineCore.Note] {
            var sorted = notes.sorted { lhs, rhs in
                lhs.start_s == rhs.start_s ? lhs.midi < rhs.midi : lhs.start_s < rhs.start_s
            }
            var result: [EngineCore.Note] = []
            for note in sorted {
                if let last = result.last, note.start_s < last.end_s {
                    let truncated = EngineCore.Note(start_s: last.start_s, end_s: note.start_s,
                                         midi: last.midi, cents_ref: last.cents_ref,
                                         confidence: last.confidence, unison: last.unison,
                                         salience: last.salience,
                                         assignmentBand: last.assignmentBand)
                    if truncated.end_s > truncated.start_s {
                        result[result.count - 1] = truncated
                    } else {
                        result.removeLast()
                    }
                }
                result.append(note)
            }
            return result
        }

        /// Where a live note came from — the ENGINE's original array index.
        enum NoteOriginIndex: Equatable {
            case engine(Int)
        }

        private static func note(at origin: NoteOriginIndex, in notes: [EngineCore.Note]) -> EngineCore.Note? {
            switch origin {
            case .engine(let index): return notes.indices.contains(index) ? notes[index] : nil
            }
        }

        private static func remove(origin: NoteOriginIndex, from part: Part,
                                   working: inout [Part: [EngineCore.Note]]) {
            guard var notes = working[part] else { return }
            switch origin {
            case .engine(let index):
                guard notes.indices.contains(index) else { return }
                notes.remove(at: index)
            }
            working[part] = notes
        }
    }
}
