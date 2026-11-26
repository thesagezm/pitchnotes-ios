import Foundation

// P-305 · NoteTrack v1.1 metadata — the per-note / per-track fields of
// CONTRACTS C-10.0, C-10.1 and C-10.2, with D-41's numbers (PAUL lane).
//
// WHAT THIS FILE IS: the ENGINE-side writer for the v1.1 note track, plus the
// ONE derivation of D-41's semantics (the band thresholds, the phrase grid, the
// presence bar and the unison rule) so that the app and the engine cannot
// drift apart. Jess's roll derives the same values locally today (which is
// CORRECT under the absence rule); after this lands the swap is ONE place —
// `NoteTrackMetadata` — instead of two copies of the thresholds.
//
// THE ABSENCE RULE IS BINDING (C-10.0): every field added here is OPTIONAL.
// A consumer that meets a note file WITHOUT these fields MUST behave exactly
// as it did before v1.1. A v0.0 note file stays valid forever (C-2.3) and is
// validated under V7–V10 only (C-10.1).
//
// HONESTY (AGENTS §11 / C-12): `salience` is the MODEL'S POSTERIOR STRENGTH,
// NOT a calibrated probability. It is carried through verbatim — never
// rescaled into a "confidence", never used as a silent filter. The
// `confidence` field is the ASSIGNMENT confidence (D-41 §1, the normalized
// posterior over the candidate part set) — a different quantity, and the two
// are never mixed.
//
// PORTABILITY: Foundation-only, no ONNX / C++ / AVFoundation (AGENTS §0).

// MARK: - The assignment band (D-41 §1)

/// D-41 §1's confidence bands. The raw strings are CONTRACT values and are
/// stable forever (C-10.0: "the three exact spellings above").
public enum AssignmentBand: String, Codable, Equatable, Sendable, CaseIterable {
    /// `c >= 0.80` — rendered solid, auto-accepted, graded.
    case confirmed = "CONFIRMED"
    /// `0.50 <= c < 0.80` — rendered shaded, editable, graded.
    case provisional = "PROVISIONAL"
    /// `c < 0.50` — excluded from grading by default (the user may force-assign).
    case unassigned = "UNASSIGNED"

    /// D-41 §1: at or above this confidence the note is CONFIRMED.
    public static let confirmedThreshold: Double = 0.80
    /// D-41 §1: at or above this confidence (and below `confirmedThreshold`)
    /// the note is PROVISIONAL.
    public static let provisionalThreshold: Double = 0.50

    /// The band a confidence falls into (D-41 §1's thresholds).
    public static func band(forConfidence confidence: Double) -> AssignmentBand {
        if confidence >= confirmedThreshold { return .confirmed }
        if confidence >= provisionalThreshold { return .provisional }
        return .unassigned
    }
}

// MARK: - The per-track v1.1 fields

/// C-10.0's `partPresence[]` entry — D-41 §2's part-presence per phrase.
///
/// A part is PRESENT in a phrase iff it has at least one note there AND the
/// mean assignment confidence of its notes in that phrase is at or above
/// `PartPresence.presenceThreshold`. ABSENT parts are DIMMED, never hidden
/// (D-41 §2 / AGENTS §11).
public struct PartPresence: Codable, Equatable, Sendable {
    /// The phrase's index (0-based, ascending — V17).
    public var phraseIndex: Int
    /// The phrase's start, in seconds from song start.
    public var start_s: Double
    /// The phrase's end, in seconds from song start. V17: `start_s < end_s`.
    public var end_s: Double
    /// Whether the part is present in this phrase (D-41 §2).
    public var present: Bool
    /// The mean assignment confidence of this part's notes in the phrase, [0,1].
    /// Zero when the part has no note there (V17).
    public var meanConfidence: Double
    /// How many notes of this part start inside the phrase (V17: ≥ 0).
    public var noteCount: Int

    /// D-41 §2: the mean-confidence bar for PRESENCE.
    public static let presenceThreshold: Double = 0.60

    public init(phraseIndex: Int, start_s: Double, end_s: Double,
                present: Bool, meanConfidence: Double, noteCount: Int) {
        self.phraseIndex = phraseIndex
        self.start_s = start_s
        self.end_s = end_s
        self.present = present
        self.meanConfidence = meanConfidence
        self.noteCount = noteCount
    }
}

/// C-10.0's `assignmentSummary` — the CONFIRMED / PROVISIONAL / UNASSIGNED
/// split for one part (D-41 §1).
public struct AssignmentSummary: Codable, Equatable, Sendable {
    public var confirmed: Int
    public var provisional: Int
    public var unassigned: Int

    public init(confirmed: Int, provisional: Int, unassigned: Int) {
        self.confirmed = confirmed
        self.provisional = provisional
        self.unassigned = unassigned
    }

    /// The total number of counted notes.
    public var total: Int { confirmed + provisional + unassigned }
}

// MARK: - Phrases

/// One phrase: a contiguous span of the note track (D-41 §2).
///
/// WITHOUT a score the spans are fixed **4.0 s** windows; WITH a score they
/// are BAR-ALIGNED and P-304's alignment supplies them. The engine never
/// guesses bar lines itself (D-40: the parser never aligns by itself).
public struct PhraseSpan: Equatable, Sendable {
    /// The phrase's index (0-based).
    public var index: Int
    /// The phrase's start, in seconds.
    public var start_s: Double
    /// The phrase's end, in seconds.
    public var end_s: Double

    public init(index: Int, start_s: Double, end_s: Double) {
        self.index = index
        self.start_s = start_s
        self.end_s = end_s
    }

    /// D-41 §2's fixed phrase length (the no-score case).
    public static let defaultSpanSeconds: Double = 4.0

    /// The fixed 4.0 s phrase grid over a track of `duration` seconds.
    ///
    /// The grid starts at 0.0 and the LAST span is truncated to the track's
    /// duration (a 4.7 s track ⇒ one span [0, 4.7], not two). A track with no
    /// duration has NO phrases — the absence rule then keeps the consumer
    /// exactly where it was.
    public static func fixedGrid(duration: Double,
                                 spanSeconds: Double = defaultSpanSeconds) -> [PhraseSpan] {
        guard duration > 0, spanSeconds > 0 else { return [] }
        var spans: [PhraseSpan] = []
        var index = 0
        var start = 0.0
        while start < duration {
            let end = min(start + spanSeconds, duration)
            spans.append(PhraseSpan(index: index, start_s: start, end_s: end))
            index += 1
            start = end
        }
        return spans
    }

    /// Does a time fall inside this span? The span is half-open
    /// (`start_s <= t < end_s`); the LAST span of a grid includes its end, so
    /// a note exactly at the track's end still lands in a phrase.
    public func contains(_ time: Double, isLast: Bool = false) -> Bool {
        if time < start_s { return false }
        return isLast ? time <= end_s : time < end_s
    }
}

// MARK: - The assignment's per-note output

/// One note as the ASSIGNMENT (P-303) produced it, before it becomes a
/// contract note.
///
/// `confidence` here is the ASSIGNMENT confidence `c` (D-41 §1) — the
/// normalized posterior of the assigned part over the candidate part set. It
/// becomes the contract note's `confidence` (C-2.3's field, whose meaning is
/// NOT redefined by v1.1) and it is what the band and the presence bar are
/// computed from.
public struct AssignedNote: Equatable, Sendable {
    /// Seconds from song start.
    public var start_s: Double
    /// Seconds from song start (V7: `start_s < end_s`).
    public var end_s: Double
    /// The MIDI note number (V9: 24–96).
    public var midi: Int
    /// Deviation from equal temperament, [-50, +50].
    public var cents_ref: Int
    /// The assignment confidence `c`, [0,1] (D-41 §1).
    public var confidence: Double
    /// The model's posterior strength for this note, [0,1] (P-302, OPTIONAL).
    /// NOT a calibrated probability and NEVER rescaled (C-12).
    public var salience: Double?

    public init(start_s: Double, end_s: Double, midi: Int,
                cents_ref: Int = 0, confidence: Double, salience: Double? = nil) {
        self.start_s = start_s
        self.end_s = end_s
        self.midi = midi
        self.cents_ref = cents_ref
        self.confidence = confidence
        self.salience = salience
    }
}

// MARK: - The writer

/// Builds the contract v1.1 note tracks from the assignment's per-part notes.
///
/// The writer is where the v1.1 metadata is COMPUTED (never guessed at read
/// time): the band from D-41 §1's thresholds, the unison flag from D-41 §3's
/// cross-part rule, the presence from D-41 §2's bar, and the summary from the
/// bands. The derived values are also what the validators check (V16–V18), so
/// a track the engine wrote and a track a consumer reads agree by
/// construction.
public enum NoteTrackV11Builder {

    /// Build one v1.1 track for one part.
    ///
    /// - Parameters:
    ///   - part: the part this track belongs to.
    ///   - notes: the assignment's notes for this part.
    ///   - spans: the phrase spans (the 4.0 s grid, or P-304's bar map).
    ///   - engineVersion: C-10.2's per-track engine version.
    ///   - unison: D-41 §3's unison flags, one per note (same order). When
    ///     nil, the flags are COMPUTED from `otherParts` — pass the other
    ///     parts' notes so the cross-part rule can be applied.
    ///   - otherParts: the other parts' notes, used for the unison rule.
    public static func build(part: Part,
                             notes: [AssignedNote],
                             spans: [PhraseSpan],
                             engineVersion: String,
                             unison: [Bool]? = nil,
                             otherParts: [Part: [AssignedNote]] = [:]) -> NoteTrack {
        // The unison flags travel WITH their notes (the caller may force them
        // — e.g. after P-304's score alignment) and the pair is sorted
        // together, so a flag can never drift onto another note.
        let flags = unison ?? computeUnisonFlags(notes: notes, spans: spans, otherParts: otherParts)
        var pairs: [(note: AssignedNote, unison: Bool)] = []
        for (index, note) in notes.enumerated() {
            pairs.append((note, flags.indices.contains(index) ? flags[index] : false))
        }
        pairs.sort { lhs, rhs in
            lhs.note.start_s == rhs.note.start_s
                ? lhs.note.midi < rhs.note.midi
                : lhs.note.start_s < rhs.note.start_s
        }
        return buildTrack(part: part, pairs: pairs, spans: spans, engineVersion: engineVersion)
    }

    /// Build EVERY part's v1.1 track from the assignment's output.
    ///
    /// This is the entry point P-303 uses: it hands over the per-part notes
    /// and gets back the contract tracks, with the cross-part unison rule and
    /// the per-part presence computed once, consistently.
    public static func buildTracks(parts: [Part: [AssignedNote]],
                                   spans: [PhraseSpan],
                                   engineVersion: String) -> [Part: NoteTrack] {
        var result: [Part: NoteTrack] = [:]
        for part in parts.keys.sorted() {
            let notes = parts[part] ?? []
            var others: [Part: [AssignedNote]] = [:]
            for (otherPart, otherNotes) in parts where otherPart != part {
                others[otherPart] = otherNotes
            }
            result[part] = build(part: part,
                                 notes: notes,
                                 spans: spans,
                                 engineVersion: engineVersion,
                                 otherParts: others)
        }
        return result
    }

    /// The per-part track builder (the parts that need no cross-part context).
    static func buildTrack(part: Part,
                           pairs: [(note: AssignedNote, unison: Bool)],
                           spans: [PhraseSpan],
                           engineVersion: String) -> NoteTrack {
        var contractNotes: [Note] = []
        contractNotes.reserveCapacity(pairs.count)
        var summary = AssignmentSummary(confirmed: 0, provisional: 0, unassigned: 0)
        for pair in pairs {
            let note = pair.note
            let band = AssignmentBand.band(forConfidence: note.confidence)
            switch band {
            case .confirmed: summary.confirmed += 1
            case .provisional: summary.provisional += 1
            case .unassigned: summary.unassigned += 1
            }
            contractNotes.append(Note(start_s: note.start_s,
                                      end_s: note.end_s,
                                      midi: note.midi,
                                      cents_ref: note.cents_ref,
                                      confidence: note.confidence,
                                      unison: pair.unison,
                                      salience: note.salience,
                                      assignmentBand: band.rawValue))
        }

        let presence = computePresence(notes: pairs.map { $0.note }, spans: spans)
        return NoteTrack(contractVersion: NoteTrack.contractVersionV11,
                         part: part,
                         notes: contractNotes,
                         engineVersion: engineVersion,
                         partPresence: presence,
                         assignmentSummary: summary)
    }

    /// D-41 §3's unison rule: two or more parts assigned the SAME MIDI pitch
    /// within ±25 cents in the SAME phrase ⇒ every one of those notes carries
    /// `unison: true`.
    ///
    /// The phrase of a note is the span its START falls into. The ±25 cents
    /// comparison uses the notes' `cents_ref` (the deviation from equal
    /// temperament) — the contract's own representation of "same pitch".
    public static func computeUnisonFlags(notes: [AssignedNote],
                                          spans: [PhraseSpan],
                                          otherParts: [Part: [AssignedNote]]) -> [Bool] {
        let others = otherParts.values.flatMap { $0 }
        guard !others.isEmpty else { return notes.map { _ in false } }
        return notes.map { note in
            let phrase = phraseIndex(of: note.start_s, spans: spans)
            for other in others {
                guard other.midi == note.midi else { continue }
                guard abs(other.cents_ref - note.cents_ref) <= unisonCentsTolerance else { continue }
                guard phraseIndex(of: other.start_s, spans: spans) == phrase else { continue }
                return true
            }
            return false
        }
    }

    /// D-41 §3's unison tolerance, in cents.
    public static let unisonCentsTolerance: Int = 25

    /// The phrase index a time falls into (nil when it falls outside every
    /// span — e.g. a note past the end of the grid).
    public static func phraseIndex(of time: Double, spans: [PhraseSpan]) -> Int? {
        for (index, span) in spans.enumerated() {
            if span.contains(time, isLast: index == spans.count - 1) { return span.index }
        }
        return nil
    }

    /// D-41 §2's presence per phrase, for one part.
    ///
    /// A note belongs to the phrase its START falls into (a note that straddles
    /// a boundary is counted once, in the phrase it starts in — the rule is
    /// deterministic and stated, not left to a consumer's guess).
    public static func computePresence(notes: [AssignedNote], spans: [PhraseSpan]) -> [PartPresence] {
        spans.map { span in
            let inPhrase = notes.filter { note in
                guard let index = phraseIndex(of: note.start_s, spans: spans) else { return false }
                return index == span.index
            }
            let count = inPhrase.count
            let mean = count > 0
                ? inPhrase.reduce(0.0) { $0 + $1.confidence } / Double(count)
                : 0.0
            let present = count >= 1 && mean >= PartPresence.presenceThreshold
            return PartPresence(phraseIndex: span.index,
                                start_s: span.start_s,
                                end_s: span.end_s,
                                present: present,
                                meanConfidence: mean,
                                noteCount: count)
        }
    }
}

// MARK: - The consumer-side derivation (ONE semantic, never two)

/// The consumer-side view of the v1.1 metadata.
///
/// EVERY accessor here implements the ABSENCE RULE: when the field is absent,
/// the value is DERIVED from what IS present (the confidence, the notes) —
/// which is exactly what a consumer did before v1.1 existed. The app and the
/// engine therefore agree by construction (the D-33 "one semantic, never two"
/// pattern).
public enum NoteTrackMetadata {

    /// The band of a note: the note's own band when it carries a valid one,
    /// else D-41 §1's derivation from the confidence.
    ///
    /// A note whose `assignmentBand` string is not one of the three exact
    /// spellings falls back to the derivation — the invalid string is a V16
    /// CONTRACT VIOLATION that the validator REPORTS; the consumer must not
    /// crash on it, and it must not pretend the string was meaningful.
    public static func band(for note: Note) -> AssignmentBand {
        if let raw = note.assignmentBand, let band = AssignmentBand(rawValue: raw) {
            return band
        }
        return AssignmentBand.band(forConfidence: note.confidence)
    }

    /// Is the note a unison note? ABSENT ⇒ false (C-10.0).
    public static func isUnison(_ note: Note) -> Bool {
        note.unison ?? false
    }

    /// The presence entry for a phrase, when the track carries one.
    public static func presence(for track: NoteTrack, phraseIndex: Int) -> PartPresence? {
        track.partPresence?.first { $0.phraseIndex == phraseIndex }
    }

    /// The CONFIRMED / PROVISIONAL / UNASSIGNED split for a track: the track's
    /// own summary when it carries one, else the counts derived from the
    /// notes' bands (C-10.0: "the consumer MAY compute the counts").
    public static func summary(for track: NoteTrack) -> AssignmentSummary {
        if let summary = track.assignmentSummary { return summary }
        var summary = AssignmentSummary(confirmed: 0, provisional: 0, unassigned: 0)
        for note in track.notes {
            switch band(for: note) {
            case .confirmed: summary.confirmed += 1
            case .provisional: summary.provisional += 1
            case .unassigned: summary.unassigned += 1
            }
        }
        return summary
    }

    /// The track's engine version. ABSENT ⇒ `"unknown"` (C-10.0: "a consumer
    /// MUST NOT invent a value").
    public static func engineVersion(for track: NoteTrack) -> String {
        track.engineVersion ?? "unknown"
    }
}
