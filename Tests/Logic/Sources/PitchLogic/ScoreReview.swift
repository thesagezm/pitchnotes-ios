import Foundation
import EngineCore

// ScoreReview (J-304) — the score-informed track and the alignment review.
//
// CONTRACTS v1.1 · C-13 (score-note list + alignment metadata) + C-14
// (grading input order). D-40: the MusicXML parser is PAUL's and lives in the
// portable engine core; the parser NEVER aligns by itself (parsing and
// alignment are separate steps, and only alignment produces C-13.2). THIS FILE
// IS THE CONSUMER — it writes no parser and it aligns nothing.
//
// THE SEAM: `ScoreImportService` (below) is a LANE-LOCAL PROTOCOL — the
// J-105 `RibbonFrameSource` / J-208 `MicLevelSource` precedent. When P-304
// lands, ONE adapter maps EngineCore's parser + aligner onto this protocol and
// nothing else in the app changes.
//
// THE HONEST LIMITS (both are filed as X-tasks, neither is self-ratified):
//   · C-11's op set is EXACTLY `reassign` / `delete` / `split` — there is NO
//     time-shift op, and the overlay addresses the ENGINE's notes, not the
//     score's — so a manual NUDGE has no persisted home yet. The nudge works
//     in-session (in memory, visible, undoable) and is NOT pretended to be
//     saved;
//   · C-13.2's alignment JSON has NO score-part → C-1-part mapping, even
//     though C-13.1 says the mapping is "the alignment's business" — so a
//     consumer that reads only the contract JSON cannot rebuild a per-part
//     score track. The mapping therefore travels with the alignment RESULT
//     (`ScoreAlignmentResult.partMapping`), not inside the JSON.
//
// WHAT C-14 FIXES (the order, verbatim):
//   1. the correction overlay, if present — AUTHORITATIVE;
//   2. else the score-informed track, if the alignment succeeded with
//      confidence ≥ 0.70 AND it improved note agreement;
//   3. else the heuristic track — and the UI must say "heuristic" and report
//      the CONFIRMED / PROVISIONAL / UNASSIGNED split.
//
// WHAT C-13 FIXES (and this file obeys):
//   · the score is OPTIONAL end-to-end — absent ⇒ heuristic-only;
//   · a score-informed track NEVER replaces the heuristic track ON DISK (the
//     engine's `notes/<PART>.json` stays exactly what the engine wrote);
//   · `used` is READ, never assumed.

// MARK: - C-13.1 · The score-note list

/// One note of the score-note list (C-13.1).
///
/// JSON: `{ "midi", "start_s", "end_s", "measure", "part_id", "voice" }` —
/// the property names ARE the JSON keys, so the synthesized `Codable`
/// conformance is the contract's shape exactly.
public struct ScoreNote: Codable, Equatable, Sendable {
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
}

/// The score-note list (C-13.1).
///
/// JSON: `{ "contractVersion": "v1.1", "scoreNotes": [...] }`.
public struct ScoreNoteList: Codable, Equatable, Sendable {
    public static let currentContractVersion = "v1.1"

    public var contractVersion: String
    public var scoreNotes: [ScoreNote]

    public init(contractVersion: String = ScoreNoteList.currentContractVersion,
                scoreNotes: [ScoreNote]) {
        self.contractVersion = contractVersion
        self.scoreNotes = scoreNotes
    }
}

// MARK: - C-13.2 · The alignment metadata

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
}

/// The alignment metadata (C-13.2).
///
/// JSON (inside the file's `alignment` object): `{ "confidence", "used",
/// "barMap", "method" }`. `method` is OPTIONAL — absent ⇒ `"unknown"`.
public struct ScoreAlignment: Codable, Equatable, Sendable {
    public var confidence: Double
    /// Whether this alignment was actually applied to the graded track. A
    /// consumer MUST NOT assume `used == true` — it is READ.
    public var used: Bool
    public var barMap: [BarMapEntry]
    /// Free string (e.g. `"DTW"`). Absent ⇒ `"unknown"`.
    public var method: String?

    public init(confidence: Double, used: Bool, barMap: [BarMapEntry], method: String? = nil) {
        self.confidence = confidence
        self.used = used
        self.barMap = barMap
        self.method = method
    }

    /// The method name, or `"unknown"` when the field was absent (C-13.2).
    public var methodName: String { method ?? "unknown" }

    /// The bar-map entry for a measure (nil when the map does not cover it).
    public func bar(for measure: Int) -> BarMapEntry? {
        barMap.first { $0.measure == measure }
    }

    /// The bar starts, in measure order — the `barStarts` the piano roll takes
    /// to make its phrases bar-aligned (D-41 §2).
    public var barStarts: [Double] {
        barMap.sorted { $0.measure < $1.measure }.map(\.start_s)
    }
}

/// The alignment FILE (C-13.2's example shape):
/// `{ "contractVersion": "v1.1", "alignment": { ... } }`.
public struct ScoreAlignmentFile: Codable, Equatable, Sendable {
    public static let currentContractVersion = "v1.1"

    public var contractVersion: String
    public var alignment: ScoreAlignment

    public init(contractVersion: String = ScoreAlignmentFile.currentContractVersion,
                alignment: ScoreAlignment) {
        self.contractVersion = contractVersion
        self.alignment = alignment
    }
}

/// The alignment RESULT: C-13.2's metadata PLUS the score-part → C-1-part
/// mapping.
///
/// C-13.1 says the mapping from `part_id` to a C-1 part "is the alignment's
/// business" — but C-13.2's JSON has NO field for it, so it cannot be read
/// back from the contract file. It therefore travels HERE (an X-task asks
/// Leto where the contract should carry it).
public struct ScoreAlignmentResult: Equatable, Sendable {
    public var alignment: ScoreAlignment
    /// The score's `part_id` → the C-1 part it was aligned to.
    public var partMapping: [String: Part]

    public init(alignment: ScoreAlignment, partMapping: [String: Part]) {
        self.alignment = alignment
        self.partMapping = partMapping
    }
}

// MARK: - The seam (the swap to P-304 lives here)

/// Why a score import could not produce a review.
public enum ScoreImportError: Error, Equatable {
    /// The parser/aligner is not in this build (P-304 has not landed).
    case parserUnavailable
    /// The score file could not be read as a score.
    case malformedScore(String)
    /// The score parsed, but the alignment failed.
    case alignmentFailed(String)
}

/// J-304's seam: the score import service.
///
/// PAUL implements it (P-304 — one Foundation `XMLParser` parser in the
/// portable engine core, and the alignment as a SEPARATE step). Until it
/// lands, the app ships the honest "not in this build" implementation and the
/// UI says exactly that.
///
/// `align` takes the DETECTED tracks because the alignment compares the score
/// with what the engine heard — and the parser NEVER aligns by itself
/// (C-13 rule 2).
public protocol ScoreImportService: Sendable {
    /// Parses a MusicXML file into the C-13.1 score-note list.
    func parseScore(data: Data) throws -> ScoreNoteList
    /// Aligns the parsed score against the detected notes (C-13.2).
    func align(score: ScoreNoteList, detected: [Part: NoteTrack]) throws -> ScoreAlignmentResult
}

// MARK: - Agreement (D-41 §4's "improved note agreement")

/// How well two note sets agree (D-41 §4's second condition for using the
/// score-informed track).
///
/// THE METRIC (deterministic, documented, symmetric):
///   · two notes MATCH when they have the SAME MIDI and their time intervals
///     overlap after both are extended by `tolerance_s`;
///   · `ratio` is the matched pairs over all pairs (a Dice-style share in
///     [0, 1]) — it counts BOTH directions, so a score that drops half the
///     song cannot look like a perfect match.
public struct ScoreAgreement: Equatable, Sendable {
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
    public static func between(score: [ScoreNote], detected: [Part: NoteTrack],
                                tolerance_s: Double = defaultTolerance_s) -> ScoreAgreement {
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
        return ScoreAgreement(matchedScoreNotes: matchedScore.count,
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

// MARK: - The aligned score notes

/// One score note after it has been placed on the audio timeline.
public struct ScoreAlignedNote: Equatable, Sendable, Identifiable {
    /// The index of this note in the score-note list (stable identity — the
    /// user's nudge is stored against it).
    public var scoreIndex: Int
    /// The C-1 part the alignment mapped it to. NIL when the score's part has
    /// no C-1 mapping — the note is still placed in time (so the agreement is
    /// honest) but it is NOT put into any part's track.
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

// MARK: - The grading reference (C-14)

/// WHICH track the grader reads (C-14 — the order is fixed).
public enum GradingReference: Equatable, Sendable {
    /// The user's corrections (C-11) — authoritative (C-14 rule 1).
    case overlay
    /// The score-informed track (C-14 rule 2).
    case scoreInformed
    /// The heuristic track (C-14 rule 3).
    case heuristic

    /// A plain-language label for the UI.
    public var label: String {
        switch self {
        case .overlay: return "your corrections"
        case .scoreInformed: return "the score"
        case .heuristic: return "the detected notes"
        }
    }
}

// MARK: - The review

/// The whole alignment review: the score, the alignment, the derived track,
/// the agreement before and after, the user's decision and the user's nudges.
///
/// This is PURE LOGIC (no UI, no file system) so every rule is unit-tested.
public struct ScoreReview: Equatable, Sendable {

    /// D-41 §4's threshold: the score-informed track needs confidence ≥ 0.70.
    public static let confidenceThreshold: Double = 0.70

    // MARK: Inputs

    /// The parsed score (C-13.1).
    public let score: ScoreNoteList
    /// The alignment (C-13.2) + the part mapping.
    public let alignmentResult: ScoreAlignmentResult
    /// The tracks the score is compared with — the EFFECTIVE (corrected)
    /// tracks when J-302's overlay is present, else the engine's tracks.
    public let detected: [Part: NoteTrack]
    /// True when a correction overlay exists (C-14 rule 1 ⇒ the overlay
    /// wins and the score is advisory only).
    public let hasOverlay: Bool

    // MARK: User state

    /// Did the user ACCEPT the alignment? (The accept/reject action IS the
    /// consumer's "used" decision — C-13.2's `used` is read, not assumed.)
    public var accepted: Bool
    /// The user's MANUAL NUDGES, in seconds, by score-note index.
    ///
    /// HONESTY: C-11 has NO time-shift op and addresses the ENGINE's notes,
    /// so a nudge has NO persisted home yet (an X-task asks Leto). The nudge
    /// is in-session, visible and undoable — it is NOT pretended to be saved.
    public var nudges: [Int: Double]

    public init(score: ScoreNoteList, alignmentResult: ScoreAlignmentResult,
                detected: [Part: NoteTrack], hasOverlay: Bool,
                accepted: Bool = false, nudges: [Int: Double] = [:]) {
        self.score = score
        self.alignmentResult = alignmentResult
        self.detected = detected
        self.hasOverlay = hasOverlay
        self.accepted = accepted
        self.nudges = nudges
    }

    // MARK: Derived — the aligned notes

    /// The score notes placed on the audio timeline (bar-mapped), with the
    /// user's nudges applied.
    ///
    /// A score note is LEFT OUT (and reported by `unplacedScoreNotes`) when
    /// the bar map does not cover its measure. A note whose score part has no
    /// C-1 mapping is placed in time but carries NO part (and is reported by
    /// `unmappedScoreNotes`) — never guessed into a part.
    public var alignedNotes: [ScoreAlignedNote] {
        ScoreReview.align(score: score,
                          alignment: alignmentResult.alignment,
                          mapping: alignmentResult.partMapping,
                          nudges: nudges)
    }

    /// The score notes that could not be placed in time (the bar map does not
    /// cover their measure).
    public var unplacedScoreNotes: [ScoreNote] {
        let placed = Set(alignedNotes.map(\.scoreIndex))
        return score.scoreNotes.enumerated()
            .filter { !placed.contains($0.offset) }
            .map(\.element)
    }

    /// The placed score notes whose score part could not be mapped to a C-1
    /// part — they are in the comparison, but in no part's track.
    public var unmappedScoreNotes: [ScoreAlignedNote] {
        alignedNotes.filter { $0.part == nil }
    }

    // MARK: Derived — the agreement

    /// The agreement of the RAW score (at the score's own tempo) with the
    /// detected notes.
    public var agreementBefore: ScoreAgreement {
        ScoreAgreement.between(score: score.scoreNotes, detected: detected)
    }

    /// The agreement of the ALIGNED score with the detected notes.
    public var agreementAfter: ScoreAgreement {
        let aligned = alignedNotes.map {
            ScoreNote(midi: $0.midi, start_s: $0.alignedStart_s, end_s: $0.alignedEnd_s,
                      measure: $0.measure, part_id: $0.scorePartID, voice: $0.voice)
        }
        return ScoreAgreement.between(score: aligned, detected: detected)
    }

    /// Did the alignment IMPROVE the agreement (D-41 §4's second condition)?
    ///
    /// THE BASELINE (documented, and filed as an X-task so Leto can rule on
    /// it): the RAW score's agreement with the detected notes. The alignment
    /// must make the score agree STRICTLY BETTER than the unaligned score
    /// did — an alignment that changes nothing (or makes it worse) does not
    /// earn the score the right to be the grading reference.
    public var agreementImproved: Bool {
        agreementAfter.ratio > agreementBefore.ratio
    }

    /// Is the alignment's confidence good enough (D-41 §4's first condition)?
    public var confidenceSufficient: Bool {
        alignmentResult.alignment.confidence >= ScoreReview.confidenceThreshold
    }

    // MARK: Derived — the C-14 decision

    /// The grading reference (C-14 — the first match wins).
    public var reference: GradingReference {
        if hasOverlay { return .overlay }
        if accepted && eligibleForScoreInformed { return .scoreInformed }
        return .heuristic
    }

    /// Both of C-14 rule 2's conditions — the score-informed track may be used.
    public var eligibleForScoreInformed: Bool {
        confidenceSufficient && agreementImproved
    }

    /// The score-informed track — DERIVED, never written over the engine's
    /// track (C-13 rule 3).
    ///
    /// Its notes carry the ALIGNMENT's confidence: the score has no per-note
    /// confidence of its own, and inventing one would be a lie (the UI shows
    /// the alignment's confidence, not a fake per-note number).
    public var scoreInformedTracks: [Part: NoteTrack] {
        var byPart: [Part: [Note]] = [:]
        for aligned in alignedNotes {
            guard let part = aligned.part else { continue }
            byPart[part, default: []].append(
                Note(start_s: aligned.alignedStart_s, end_s: aligned.alignedEnd_s,
                     midi: aligned.midi, cents_ref: 0,
                     confidence: alignmentResult.alignment.confidence))
        }
        var tracks: [Part: NoteTrack] = [:]
        for part in byPart.keys.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let outcome = NoteTrackRepair.repair(byPart[part] ?? [])
            tracks[part] = NoteTrack(part: part, notes: outcome.notes)
        }
        return tracks
    }

    /// The reference tracks — what the grader would read (C-14).
    public var referenceTracks: [Part: NoteTrack] {
        switch reference {
        case .overlay, .heuristic: return detected
        case .scoreInformed: return scoreInformedTracks
        }
    }

    /// The CONFIRMED / PROVISIONAL / UNASSIGNED split of the detected notes
    /// (D-41 §1) — C-14 rule 3 requires the UI to REPORT it whenever the
    /// heuristic track is the reference.
    public var bandSummary: [ConfidenceBand: Int] {
        var counts: [ConfidenceBand: Int] = [:]
        for note in detected.values.flatMap(\.notes) {
            counts[ConfidenceBand(confidence: note.confidence), default: 0] += 1
        }
        return counts
    }

    // MARK: The user's actions

    /// Accept the alignment (the user says "this score matches my recording").
    public mutating func accept() { accepted = true }

    /// Reject the alignment — the heuristic track stays intact (C-13 rule 3:
    /// a score-informed track NEVER replaces the heuristic track on disk).
    public mutating func reject() { accepted = false }

    /// Nudge one score note by `seconds` (positive = later).
    public mutating func nudge(scoreIndex: Int, by seconds: Double) {
        nudges[scoreIndex, default: 0] += seconds
    }

    /// Undo every nudge.
    public mutating func resetNudges() { nudges.removeAll() }

    /// The nudge applied to one score note (0 when there is none).
    public func nudge(for scoreIndex: Int) -> Double {
        nudges[scoreIndex] ?? 0
    }

    // MARK: The alignment itself

    /// Places the score notes on the audio timeline.
    ///
    /// THE MAPPING (deterministic, documented): a score note in measure M is
    /// anchored to the bar-map entry for M. The bar's AUDIO start is where the
    /// measure's FIRST score note lands; the score's own intra-measure timing
    /// is preserved (a measure with two or more notes is scaled onto the bar's
    /// audio span; a measure with a single note keeps its own duration).
    ///
    /// A score note is skipped when the bar map does not cover its measure.
    /// Its C-1 part is the alignment's mapping (nil when the score's part is
    /// unmapped — the note is never guessed into a part).
    ///
    /// The contract fixes the bar map's SHAPE, not the algorithm that produced
    /// it (P-304's alignment may be DTW) — this is the consumer's mapping.
    static func align(score: ScoreNoteList, alignment: ScoreAlignment,
                      mapping: [String: Part], nudges: [Int: Double]) -> [ScoreAlignedNote] {
        var measureSpans: [Int: (start: Double, end: Double, count: Int)] = [:]
        for note in score.scoreNotes {
            var span = measureSpans[note.measure] ?? (note.start_s, note.end_s, 0)
            span.start = min(span.start, note.start_s)
            span.end = max(span.end, note.end_s)
            span.count += 1
            measureSpans[note.measure] = span
        }

        var result: [ScoreAlignedNote] = []
        for (index, note) in score.scoreNotes.enumerated() {
            guard let bar = alignment.bar(for: note.measure) else { continue }
            let span = measureSpans[note.measure]
            let scoreSpan = max(span.end - span.start, 0)
            let audioSpan = max(bar.end_s - bar.start_s, 0)
            let scale: Double = (span.count > 1 && scoreSpan > 0) ? audioSpan / scoreSpan : 1
            let offset = (note.start_s - span.start) * scale
            let length = (note.end_s - note.start_s) * scale
            let nudge = nudges[index] ?? 0
            result.append(ScoreAlignedNote(
                scoreIndex: index,
                part: mapping[note.part_id],
                midi: note.midi,
                scoreStart_s: note.start_s,
                scoreEnd_s: note.end_s,
                alignedStart_s: bar.start_s + offset + nudge,
                alignedEnd_s: bar.start_s + offset + length + nudge,
                measure: note.measure,
                scorePartID: note.part_id,
                voice: note.voice))
        }
        return result
    }
}
