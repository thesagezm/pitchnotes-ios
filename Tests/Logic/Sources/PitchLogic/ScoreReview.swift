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
// THE TWO GAPS D-47 CLOSED (both were filed as X-tasks):
//   · THE SCORE'S NUDGE NOW HAS A HOME (C-16, D-47 §7): the file
//     `corrections/score.json` beside C-11's and C-15's, carrying
//     `{scoreEdits:[{scoreIndex, offset_s}]}`. It moves the SCORE's times,
//     never the engine's notes, and it is deliberately NOT a C-11 op (the
//     engine's and the score's index spaces are different). See
//     `ScoreEditOverlay` / `ScoreEditStore`;
//   · THE SCORE-PART → C-1-PART MAPPING NOW TRAVELS IN THE CONTRACT JSON
//     (C-13.2 v1.1.1, D-47 §8): the alignment object's optional
//     `partMapping`. ABSENT ⇒ no score note enters any part, and a consumer
//     MUST NOT guess a mapping.
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

// MARK: - C-13 · The score-contract types (J-406 — the D-52 §5 typealias migration)

// These eight names USED to be PitchLogic's own struct definitions — a second
// copy of the shapes Paul's engine also owns. D-52 §4 ruled the same-name
// option DEAD (two imported modules exporting one public name is "'X' is
// ambiguous for type lookup"), so EngineCore defines its types under the
// `ScoreContract.*` namespace with the IDENTICAL JSON (C-13.1/C-13.2 — pinned
// byte-exact by Paul's EngineCore tests). This file IS the end-state
// migration (D-52 §5): one line per type re-exports the engine's type under
// the name the app and the tests already use — the two modules never export
// the same public name, the app's call sites compile UNCHANGED, and the D-33
// "one semantic, never two" residue collapses to zero. The JSON is NOT
// re-pinned here: it is literally ONE type now, and the pin lives with the
// definition (D-57 §2 — Jess consumes; she does not re-pin).

/// C-13.1 · One note of the score-note list.
public typealias ScoreNote = ScoreContract.Note

/// C-13.1 · The score-note list
/// (`{ "contractVersion": "v1.1", "scoreNotes": [...] }`).
public typealias ScoreNoteList = ScoreContract.NoteList

/// C-13.2 · One bar-map entry (the measure's span in AUDIO seconds — the map
/// that turns D-41 §2's fixed 4.0 s phrases into BAR-ALIGNED phrases).
public typealias BarMapEntry = ScoreContract.BarMapEntry

/// C-13.2 · The alignment metadata
/// (`{ "confidence", "used", "barMap", "method", "partMapping" }`).
public typealias ScoreAlignment = ScoreContract.Alignment

/// C-13.2 · The alignment file
/// (`{ "contractVersion": "v1.1", "alignment": { ... } }`).
public typealias ScoreAlignmentFile = ScoreContract.AlignmentFile

/// C-13.2's metadata + the score-part → C-1-part mapping it carries.
public typealias ScoreAlignmentResult = ScoreContract.AlignmentResult

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

// MARK: - Agreement + the aligned notes (the same J-406 migration, one line each)

/// D-41 §4's "improved note agreement" — the METRIC is now contract-pinned
/// (C-17, D-58): same-MIDI integer equality (no octave fold), interval overlap
/// with both sides extended by `tolerance_s` (default 0.25), one-to-one, a
/// two-sided Dice ratio. Deterministic, documented, symmetric — it counts BOTH
/// directions, so a score that drops half the song cannot look like a perfect
/// match.
public typealias ScoreAgreement = ScoreContract.Agreement

/// One score note after it has been placed on the audio timeline.
public typealias ScoreAlignedNote = ScoreContract.AlignedNote

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
                detected: [Part: NoteTrack], hasOverlay: Bool = false,
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
            guard let span = measureSpans[note.measure] else { continue }
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
