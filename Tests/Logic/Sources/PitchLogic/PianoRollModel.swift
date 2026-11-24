// PianoRollModel — J-301's pure-logic core: the per-part piano roll's DATA
// model + geometry + the rules the UI must honour.
//
// NO SwiftUI, NO CoreGraphics (CoreGraphics is Apple-only and this package
// compiles + tests on Linux — the logic-tests CI job). Geometry is expressed
// with plain Double rectangles (`RollRect`); the app converts them to CGRect.
//
// Rulings this file implements (read before changing a number):
//   · D-41 §1 — assignment-confidence BANDS: c ≥ 0.80 CONFIRMED (solid),
//     0.50 ≤ c < 0.80 PROVISIONAL (shaded), c < 0.50 UNASSIGNED (excluded from
//     grading by default; the user can force-assign it in J-302).
//   · D-41 §2 — part PRESENCE per phrase: a part is present iff it has ≥ 1 note
//     in the phrase AND the mean confidence of its notes there is ≥ 0.60.
//     ABSENT parts are DIMMED, never hidden (honesty rail, AGENTS §11).
//   · D-41 §3 — UNISON flag: two or more parts on the same MIDI pitch within
//     ±25 ¢ in the same phrase ⇒ every one of those notes carries the flag.
//     Grading stays per-part (a unison never double-counts one singer).
//   · D-41 §4 — the CORRECTION OVERLAY is authoritative for grading (J-302).
//     This model renders the track it is GIVEN; the caller decides whether
//     that is the raw track or the corrected one.
//   · D-40 §3 / D-12 — a missing score never fails anything: the roll degrades
//     to the heuristic track (the `barStarts` argument is optional).
//   · UX §3.2 — the time model is pixels-per-second (`pps`), one token, never
//     per-screen; UX §3.3 — pitch is CENTS, linear.
//   · UX §A.2.4 — transpose moves the DISPLAYED reference only; the stored
//     audio stays byte-true, and the display is clamped to the part's singable
//     range so a transpose can never push a part out of its own range.
//
// CONTRACT NOTE: CONTRACTS on main is v1.0.3; v1.1 (L-301) will add the
// NoteTrack metadata fields + the correction-overlay schema. Until Leto
// ratifies v1.1 this model DERIVES the v1.1-ish facts (band, presence,
// unison) from the FROZEN C-2.3 fields (`confidence` is already in C-2.3), so
// nothing here depends on a contract that does not exist yet — when P-305
// lands the real per-note assignment confidence, it replaces `confidence` as
// the band input and NOTHING else changes.

import Foundation
import EngineCore

// MARK: - Confidence bands (D-41 §1)

/// Assignment-confidence band of one note (D-41 §1).
public enum ConfidenceBand: String, Equatable, Sendable, CaseIterable {
    /// c ≥ 0.80 — rendered solid, auto-accepted, graded.
    case confirmed
    /// 0.50 ≤ c < 0.80 — rendered shaded, editable, graded but reported as
    /// provisional (the UI invites a correction).
    case provisional
    /// c < 0.50 — excluded from grading by default; J-302 can force-assign it.
    case unassigned

    /// Band of a confidence value (D-41 §1 thresholds, verbatim).
    public init(confidence: Double) {
        if confidence >= PianoRollModel.confirmedThreshold {
            self = .confirmed
        } else if confidence >= PianoRollModel.provisionalThreshold {
            self = .provisional
        } else {
            self = .unassigned
        }
    }

    /// Graded by default? Only UNASSIGNED notes are held back (D-41 §1).
    public var isGradedByDefault: Bool { self != .unassigned }

    /// Short, honest label (the UI shows the full sentence, not just this).
    public var label: String {
        switch self {
        case .confirmed: return "confirmed"
        case .provisional: return "provisional"
        case .unassigned: return "unassigned"
        }
    }

    /// One-line explanation for the note-detail sheet (VoiceOver reads it too).
    public var explanation: String {
        switch self {
        case .confirmed:
            return "Confidence \(PianoRollModel.percentText(0.80)) or better — the assignment was accepted automatically."
        case .provisional:
            return "Confidence between \(PianoRollModel.percentText(0.50)) and \(PianoRollModel.percentText(0.80)) — a guess worth checking."
        case .unassigned:
            return "Confidence below \(PianoRollModel.percentText(0.50)) — not graded until you assign it to a part."
        }
    }
}

// MARK: - Phrases (D-41 §2)

/// One phrase of the roll. A phrase is a contiguous 4.0 s span of the note
/// track; when a score is present the spans are BAR-ALIGNED instead (D-41 §2
/// — P-304's alignment defines the bar map). Without a score the 4.0 s spans
/// apply and the roll degrades to heuristic-only (D-12/D-40 §3).
public struct RollPhrase: Equatable, Sendable, Identifiable {
    public let index: Int
    public let start_s: Double
    public let end_s: Double

    public init(index: Int, start_s: Double, end_s: Double) {
        self.index = index
        self.start_s = start_s
        self.end_s = end_s
    }

    public var id: Int { index }
    public var duration_s: Double { end_s - start_s }

    /// The phrase containing `time` (clamped to the first/last phrase).
    public func contains(_ time: Double) -> Bool {
        time >= start_s && time < end_s
    }
}

/// Part presence in one phrase (D-41 §2). ABSENT ⇒ DIMMED, never hidden.
public struct PartPhrasePresence: Equatable, Sendable {
    public let part: Part
    public let phraseIndex: Int
    /// Mean confidence of the part's notes in the phrase.
    public let meanConfidence: Double
    /// D-41 §2: present iff ≥ 1 note AND mean confidence ≥ 0.60.
    public let isPresent: Bool
    /// Number of notes the part has in this phrase (0 ⇒ absent).
    public let noteCount: Int

    public init(part: Part, phraseIndex: Int, meanConfidence: Double, isPresent: Bool, noteCount: Int) {
        self.part = part
        self.phraseIndex = phraseIndex
        self.meanConfidence = meanConfidence
        self.isPresent = isPresent
        self.noteCount = noteCount
    }
}

// MARK: - One note on the roll

/// A note as the roll renders it: the raw C-2.3 `Note` plus the derived
/// facts (band, phrase, unison).
public struct PianoRollNote: Identifiable, Equatable, Sendable {
    /// Owning part.
    public let part: Part
    /// Index of the note inside its part's track (stable identity).
    public let noteIndex: Int
    /// The contract note (C-2.3).
    public let note: Note
    /// Phrase the note falls in.
    public let phraseIndex: Int
    /// D-41 §1 band.
    public let band: ConfidenceBand
    /// D-41 §3 unison flag.
    public let isUnison: Bool

    public init(part: Part, noteIndex: Int, note: Note, phraseIndex: Int,
                band: ConfidenceBand, isUnison: Bool) {
        self.part = part
        self.noteIndex = noteIndex
        self.note = note
        self.phraseIndex = phraseIndex
        self.band = band
        self.isUnison = isUnison
    }

    public var id: String { "\(part.rawValue)#\(noteIndex)" }

    /// Absolute pitch position in cents (midi·100 + cents_ref, C-2.3).
    public var absoluteCents: Double {
        Double(note.midi) * 100 + Double(note.cents_ref)
    }

    public var duration_s: Double { note.end_s - note.start_s }

    /// Scientific note name + cents ("D4 +12¢") — PitchMath owns the spelling.
    public var pitchLabel: String {
        PitchMath.noteName(forMidi: note.midi) + centsLabel(note.cents_ref)
    }

    static func centsLabel(_ cents: Int) -> String {
        cents == 0 ? "" : (cents > 0 ? " +\(cents)¢" : " −\(abs(cents))¢")
    }
}

// MARK: - Geometry (plain values — no CoreGraphics here)

/// A rectangle in view points (the app converts to CGRect).
public struct RollRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px <= x + width && py >= y && py <= y + height
    }

    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }
}

/// The roll's geometry: time on x (pixels-per-second), pitch on y (cents,
/// linear — UX §3.3). One `pixelsPerSecond` token for the whole app
/// (UX §3.2); the roll zooms it through the documented zoom levels.
public struct PianoRollLayout: Equatable, Sendable {
    /// Pixels per second (the zoom level).
    public var pixelsPerSecond: Double
    /// Height of one semitone in points.
    public var pixelsPerSemitone: Double
    /// Time at the LEFT edge of the viewport.
    public var scrollSeconds: Double
    /// Cents at the TOP edge of the viewport (higher pitch = smaller y).
    public var topCents: Double
    public var viewportWidth: Double
    public var viewportHeight: Double

    public init(pixelsPerSecond: Double, pixelsPerSemitone: Double,
                scrollSeconds: Double, topCents: Double,
                viewportWidth: Double, viewportHeight: Double) {
        self.pixelsPerSecond = pixelsPerSecond
        self.pixelsPerSemitone = pixelsPerSemitone
        self.scrollSeconds = scrollSeconds
        self.topCents = topCents
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
    }

    public func x(forTime time: Double) -> Double {
        (time - scrollSeconds) * pixelsPerSecond
    }

    public func time(forX x: Double) -> Double {
        scrollSeconds + x / pixelsPerSecond
    }

    public func y(forCents cents: Double) -> Double {
        (topCents - cents) / 100 * pixelsPerSemitone
    }

    public func cents(forY y: Double) -> Double {
        topCents - (y / pixelsPerSemitone) * 100
    }

    /// Time range currently on screen.
    public var visibleTimeRange: ClosedRange<Double> {
        let start = scrollSeconds
        let end = scrollSeconds + (viewportWidth / max(pixelsPerSecond, 0.0001))
        return start...end
    }

    /// Pitch range currently on screen.
    public var visibleCentsRange: ClosedRange<Double> {
        let high = topCents
        let low = topCents - (viewportHeight / max(pixelsPerSemitone, 0.0001)) * 100
        return low...high
    }
}

// MARK: - The model

/// The piano roll's data model (J-301). Built from `[Part: NoteTrack]` — the
/// SAME input whether the tracks come from the mock (today) or from Paul's
/// real bundle on disk (P-305) — which is what makes the mock→real swap a
/// ZERO-UI-CHANGE swap.
public struct PianoRollModel: Equatable, Sendable {

    // MARK: Thresholds (D-41, verbatim)

    /// c ≥ this ⇒ CONFIRMED (D-41 §1).
    public static let confirmedThreshold: Double = 0.80
    /// c ≥ this (and < confirmed) ⇒ PROVISIONAL (D-41 §1).
    public static let provisionalThreshold: Double = 0.50
    /// Mean-confidence floor for a part to count as PRESENT in a phrase
    /// (D-41 §2).
    public static let presenceConfidenceThreshold: Double = 0.60
    /// Unison tolerance in cents, same MIDI pitch (D-41 §3).
    public static let unisonCentsTolerance: Double = 25
    /// Phrase length in seconds when no score/bar map is available (D-41 §2).
    public static let phraseDuration_s: Double = 4.0

    // MARK: Stored state

    /// The tracks being rendered (raw engine track, or the corrected overlay
    /// track when J-302 supplies one — D-41 §4).
    public let tracks: [Part: NoteTrack]
    /// Every note, flattened, ordered by start time then C-1 part order.
    public let notes: [PianoRollNote]
    /// The phrases the roll is divided into.
    public let phrases: [RollPhrase]
    /// Part presence per phrase (D-41 §2).
    public let presence: [PartPhrasePresence]
    /// Song duration (seconds) — the roll's scroll extent.
    public let duration_s: Double
    /// Parts the user HID (toggles). A hidden part is hidden BY THE USER; an
    /// absent part is only DIMMED (D-41 §2 — never hidden).
    public var hiddenParts: Set<Part>
    /// Display-only transpose in semitones (UX §A.2.4 — the audio is never
    /// touched; the display is clamped to the part's singable range).
    public var transposeSemitones: Int

    // MARK: Init

    /// Build the roll.
    /// - Parameters:
    ///   - tracks: the note tracks to render, keyed by part.
    ///   - duration_s: song duration (the manifest's `duration_s`).
    ///   - barStarts: OPTIONAL bar map (seconds) from a score alignment
    ///     (P-304). When present the phrases are bar-aligned (D-41 §2); when
    ///     absent the phrases are contiguous 4.0 s spans and the roll is
    ///     heuristic-only (D-12/D-40 §3 — no score never breaks anything).
    public init(tracks: [Part: NoteTrack], duration_s: Double,
                barStarts: [Double]? = nil, hiddenParts: Set<Part> = [],
                transposeSemitones: Int = 0) {
        self.tracks = tracks
        self.duration_s = max(duration_s, 0)
        self.hiddenParts = hiddenParts
        self.transposeSemitones = transposeSemitones
        self.phrases = PianoRollModel.makePhrases(duration_s: max(duration_s, 0), barStarts: barStarts)
        self.notes = PianoRollModel.makeNotes(tracks: tracks, phrases: self.phrases)
        self.presence = PianoRollModel.makePresence(notes: self.notes, phrases: self.phrases, tracks: tracks)
    }

    // MARK: Parts

    /// Parts that actually have a track, in C-1 display order.
    public var parts: [Part] {
        tracks.keys
            .filter { tracks[$0]?.notes.isEmpty == false }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Parts the user can see right now (toggles applied).
    public var visibleParts: [Part] {
        parts.filter { !hiddenParts.contains($0) }
    }

    /// Notes of the visible parts.
    public var visibleNotes: [PianoRollNote] {
        notes.filter { !hiddenParts.contains($0.part) }
    }

    // MARK: Presence (D-41 §2)

    /// Presence of `part` in `phraseIndex` (nil ⇒ no data ⇒ absent).
    public func presence(part: Part, phraseIndex: Int) -> PartPhrasePresence? {
        presence.first { $0.part == part && $0.phraseIndex == phraseIndex }
    }

    /// Is the part present in the phrase? Unknown ⇒ false (dimmed).
    public func isPresent(part: Part, phraseIndex: Int) -> Bool {
        presence(part: part, phraseIndex: phraseIndex)?.isPresent ?? false
    }

    // MARK: Layout + hit testing

    /// Vertical range that fits the VISIBLE parts' notes, with a small margin.
    /// Empty roll ⇒ a neutral 2-octave window so the canvas is never blank.
    public func contentCentsRange() -> ClosedRange<Double> {
        let visible = visibleNotes
        guard !visible.isEmpty else { return 3600...6000 }
        let lows = visible.map { $0.absoluteCents + Double(transposeSemitones) * 100 }
        let highs = visible.map { $0.absoluteCents + Double(transposeSemitones) * 100 + 100 }
        let low = (lows.min() ?? 3600) - 100
        let high = (highs.max() ?? 6000) + 100
        return low...high
    }

    /// Rectangle of a note in the given layout (display transpose applied AND
    /// clamped to the part's range — the drawn note is exactly the note the
    /// user sees).
    public func rect(for note: PianoRollNote, layout: PianoRollLayout) -> RollRect {
        let displayed = displayedCents(for: note)
        let start = layout.x(forTime: note.note.start_s)
        let width = max(note.duration_s * layout.pixelsPerSecond, 2)
        let height = max(layout.pixelsPerSemitone - 1, 2)
        let y = layout.y(forCents: displayed) - height / 2
        return RollRect(x: start, y: y, width: width, height: height)
    }

    /// Notes intersecting a time window (the canvas culls with this — a 4-minute
    /// song must never draw 1000 rectangles per frame).
    public func notes(inTimeRange range: ClosedRange<Double>) -> [PianoRollNote] {
        visibleNotes.filter { $0.note.start_s <= range.upperBound && $0.note.end_s >= range.lowerBound }
    }

    /// Topmost note at a point (later parts draw on top, so the hit follows
    /// what the user sees). Hidden parts are never hit.
    public func hitTest(x: Double, y: Double, layout: PianoRollLayout) -> PianoRollNote? {
        let time = layout.time(forX: x)
        let cents = layout.cents(forY: y)
        let candidates = visibleNotes.filter { note in
            let displayed = displayedCents(for: note)
            return note.note.start_s <= time && time <= note.note.end_s
                && displayed + 100 >= cents && displayed <= cents
        }
        // The note whose rectangle contains the point, topmost first.
        for note in candidates.reversed() {
            if rect(for: note, layout: layout).contains(x: x, y: y) {
                return note
            }
        }
        return candidates.last
    }

    // MARK: Region loop (drag across notes)

    /// A dragged region in seconds (A/B loop handles for the transport).
    public struct LoopRegion: Equatable, Sendable {
        public let start_s: Double
        public let end_s: Double

        public init(start_s: Double, end_s: Double) {
            self.start_s = min(start_s, end_s)
            self.end_s = max(start_s, end_s)
        }

        public var duration_s: Double { end_s - start_s }
        public var isEmpty: Bool { end_s - start_s < 0.05 }
    }

    /// Region from a drag in view points (clamped to the song).
    public func loopRegion(fromX x0: Double, toX x1: Double, layout: PianoRollLayout) -> LoopRegion {
        let a = layout.time(forX: x0)
        let b = layout.time(forX: x1)
        return LoopRegion(start_s: min(max(a, 0), duration_s),
                          end_s: min(max(b, 0), duration_s))
    }

    // MARK: Transpose (display only, clamped to the part's range)

    /// Displayed MIDI of a note after the display transpose, clamped to the
    /// part's C-6.1 singable range (UX §A.2.4 — "range-clamped so part
    /// ranges stay singable"). Parts without a C-6.1 preset are unclamped.
    public func displayedMidi(for note: PianoRollNote) -> Int {
        let shifted = note.note.midi + transposeSemitones
        guard let range = PartRangeChips.range(for: note.part) else { return shifted }
        return min(max(shifted, range.midiLow), range.midiHigh)
    }

    /// The displayed cents of a note (after transpose + range clamp).
    public func displayedCents(for note: PianoRollNote) -> Double {
        Double(displayedMidi(for: note)) * 100 + Double(note.note.cents_ref)
    }

    // MARK: Accessibility text

    /// VoiceOver description of one note (the canvas itself is not
    /// accessible — the roll ships a text list; this is the same wording).
    public func accessibilityDescription(for note: PianoRollNote) -> String {
        var parts: [String] = []
        parts.append("\(note.part.displayName) \(note.pitchLabel)")
        parts.append(String(format: "from %.2f to %.2f seconds", note.note.start_s, note.note.end_s))
        parts.append("confidence \(PianoRollModel.percentText(note.note.confidence))")
        parts.append(note.band.label)
        if note.isUnison {
            parts.append("unison — another part sings the same pitch here, so this passage cannot be isolated by pitch")
        }
        if !isPresent(part: note.part, phraseIndex: note.phraseIndex) {
            parts.append("this part looks absent in this phrase — worth checking")
        }
        return parts.joined(separator: ". ")
    }

    /// Percentage text ("95%") for confidence readouts.
    public static func percentText(_ confidence: Double) -> String {
        String(format: "%.0f%%", confidence * 100)
    }

    // MARK: - Builders (static, pure)

    static func makePhrases(duration_s: Double, barStarts: [Double]?) -> [RollPhrase] {
        // Bar-aligned phrases when a score alignment supplied a bar map
        // (D-41 §2); contiguous 4.0 s spans otherwise.
        if let bars = barStarts, bars.count >= 2 {
            var phrases: [RollPhrase] = []
            for index in 0..<(bars.count - 1) {
                let start = max(bars[index], 0)
                let end = max(bars[index + 1], start + 0.001)
                phrases.append(RollPhrase(index: phrases.count, start_s: start, end_s: end))
            }
            if let last = bars.last, last < duration_s {
                phrases.append(RollPhrase(index: phrases.count, start_s: last,
                                          end_s: max(duration_s, last + 0.001)))
            }
            if !phrases.isEmpty { return phrases }
        }
        var phrases: [RollPhrase] = []
        var start = 0.0
        var index = 0
        while start < duration_s {
            let end = start + phraseDuration_s
            phrases.append(RollPhrase(index: index, start_s: start, end_s: end))
            start = end
            index += 1
        }
        if duration_s <= 0 {
            phrases.append(RollPhrase(index: 0, start_s: 0, end_s: phraseDuration_s))
        }
        return phrases
    }

    static func makeNotes(tracks: [Part: NoteTrack], phrases: [RollPhrase]) -> [PianoRollNote] {
        var out: [PianoRollNote] = []
        for part in tracks.keys.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            guard let track = tracks[part] else { continue }
            for (index, note) in track.notes.enumerated() {
                out.append(PianoRollNote(
                    part: part,
                    noteIndex: index,
                    note: note,
                    phraseIndex: phraseIndex(for: note.start_s, phrases: phrases),
                    band: ConfidenceBand(confidence: note.confidence),
                    isUnison: false))
            }
        }
        // D-41 §3: unison = same MIDI pitch within ±25 ¢ in the SAME phrase,
        // across two or more parts. Computed after the flat list exists so the
        // rule can look across parts.
        let unisonIds = Set(unisonNoteKeys(notes: out))
        return out
            .map { note in
                guard unisonIds.contains(note.id) else { return note }
                return PianoRollNote(part: note.part, noteIndex: note.noteIndex, note: note.note,
                                     phraseIndex: note.phraseIndex, band: note.band, isUnison: true)
            }
            .sorted { lhs, rhs in
                if lhs.note.start_s != rhs.note.start_s { return lhs.note.start_s < rhs.note.start_s }
                if lhs.part.sortOrder != rhs.part.sortOrder { return lhs.part.sortOrder < rhs.part.sortOrder }
                return lhs.noteIndex < rhs.noteIndex
            }
    }

    /// Keys (`part#index`) of notes that are in a unison (D-41 §3).
    static func unisonNoteKeys(notes: [PianoRollNote]) -> [String] {
        var out: Set<String> = []
        // Group by phrase + MIDI pitch; within a group, any two notes from
        // DIFFERENT parts whose cents differ by ≤ 25 ¢ make the whole group
        // unison.
        var groups: [String: [PianoRollNote]] = [:]
        for note in notes {
            let key = "\(note.phraseIndex)#\(note.note.midi)"
            groups[key, default: []].append(note)
        }
        for (_, group) in groups {
            guard group.count >= 2 else { continue }
            var involved = Set<String>()
            for i in group.indices {
                for j in (i + 1)..<group.count {
                    let a = group[i], b = group[j]
                    guard a.part != b.part else { continue }
                    let delta = abs(a.absoluteCents - b.absoluteCents)
                    if delta <= unisonCentsTolerance {
                        involved.insert(a.id)
                        involved.insert(b.id)
                    }
                }
            }
            out.formUnion(involved)
        }
        return Array(out)
    }

    static func phraseIndex(for time: Double, phrases: [RollPhrase]) -> Int {
        for phrase in phrases {
            if phrase.contains(time) { return phrase.index }
        }
        return phrases.isEmpty ? 0 : (time < phrases[0].start_s ? 0 : phrases.count - 1)
    }

    static func makePresence(notes: [PianoRollNote], phrases: [RollPhrase],
                             tracks: [Part: NoteTrack]) -> [PartPhrasePresence] {
        var out: [PartPhrasePresence] = []
        let parts = tracks.keys.sorted(by: { $0.sortOrder < $1.sortOrder })
        for part in parts {
            for phrase in phrases {
                let inPhrase = notes.filter { $0.part == part && $0.phraseIndex == phrase.index }
                if inPhrase.isEmpty {
                    out.append(PartPhrasePresence(part: part, phraseIndex: phrase.index,
                                                  meanConfidence: 0, isPresent: false, noteCount: 0))
                } else {
                    let mean = inPhrase.reduce(0.0) { $0 + $1.note.confidence } / Double(inPhrase.count)
                    // D-41 §2: present iff ≥ 1 note AND mean confidence ≥ 0.60.
                    let present = mean >= presenceConfidenceThreshold
                    out.append(PartPhrasePresence(part: part, phraseIndex: phrase.index,
                                                  meanConfidence: mean, isPresent: present,
                                                  noteCount: inPhrase.count))
                }
            }
        }
        return out
    }
}
