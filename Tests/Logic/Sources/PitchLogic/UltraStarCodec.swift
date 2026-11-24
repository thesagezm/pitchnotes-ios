import Foundation
import EngineCore

// UltraStarCodec (J-303) — the UltraStar `.txt` note format, implemented BY
// HAND from the frozen contract (CONTRACTS C-4).
//
// PROVENANCE / LICENSE (AGENTS §9 — a hard rail, not a nicety):
//   UltraStar, UltraStar Deluxe, Performous, Nightingale, Vocaluxe and
//   friends are STUDY-ONLY (GPL/AGPL). We never link them, never vendor
//   them, and NO code — or line of a reference implementation — is copied or
//   transcribed here. What is adopted is (a) a FILE FORMAT (a data
//   interchange convention) and (b) the C-4 semantics, reimplemented from the
//   contract text. The study-only apps are listed in AGENTS §9 so that no
//   one "helpfully" ports their parser later.
//
// C-4, verbatim:
//   · "UltraStar note token pitch is MIDI − 60 (UltraStar 0 = C4 = MIDI 60),
//      integer."
//   · "Note start/length are BEATS (ints); timing derives from #BPM (beats
//      per minute, quarter-note = 1 beat) and #GAP (ms from file start to
//      beat 0): start_s = GAP/1000 + start_beat * 60/BPM."
//   · "Round-trip rule ('lossless within schema'): midi, start_s, end_s are
//      preserved exactly (subject to BPM/GAP quantization); cents_ref resets
//      to 0 and confidence to 1.0 on import (UltraStar cannot carry them).
//      Export must round start_s/end_s to the nearest beat under the chosen
//      #BPM."
//   · "Our importer accepts standard `F : * R G` note kinds; export emits `:`
//      (normal) and `*` (golden) only in v0.0."
//
// WHAT THE FORMAT CANNOT CARRY (honest accounting, D-12):
//   · cents_ref   → resets to 0 on import (C-4).
//   · confidence  → resets to 1.0 on import (C-4).
//   · lyrics      → dropped (C-2.3's Note has no lyric field); counted and
//                   reported, never silently swallowed.
//   · note kind   → `F` (freestyle), `R` (rap) and `G` (the fifth standard
//                   kind C-4 lists) have NO definite pitch in the C-4
//                   NoteTrack mapping, and C-2.3's Note carries exactly one
//                   pitch, so they are ACCEPTED and COUNTED — never turned
//                   into a pitched note (inventing a pitch for a freestyle
//                   line would be a lie the learner could not see).
//   · a golden marker → `*` is pitched, but C-2.3's Note has no golden flag,
//                   so the bonus is out-of-band and does not survive a
//                   round-trip (counted on import, opt-in on export).
//
// ONE TRACK PER FILE: a NoteTrack is ONE part (C-2.3 carries a single
// `part`), and an UltraStar file is ONE melody. A five-part bundle therefore
// exports as FIVE files, one per part — the app names them after the part.

/// The standard UltraStar note kinds (C-4: "Our importer accepts standard
/// `F : * R G` note kinds; export emits `:` (normal) and `*` (golden) only in
/// v0.0").
public enum UltraStarNoteKind: String, Equatable, Sendable, CaseIterable {
    /// `:` — a normal pitched note. Exported.
    case normal = ":"
    /// `*` — a golden note (a scoring bonus). Pitched, but C-2.3's Note has
    /// no golden flag, so the bonus is out-of-band.
    case golden = "*"
    /// `F` — freestyle: the player may sing any pitch. No definite pitch in
    /// the C-4 mapping ⇒ accepted and counted, never pitched.
    case freestyle = "F"
    /// `R` — rap: unpitched. Accepted and counted, never pitched.
    case rap = "R"
    /// `G` — the fifth standard kind C-4 lists. C-4 does not define its note
    /// semantics, so it is accepted and counted, never pitched.
    case g = "G"

    /// Does this kind carry a definite pitch in the C-4 NoteTrack mapping?
    public var isPitched: Bool { self == .normal || self == .golden }
}

/// Why a parse could not produce a track at all.
public enum UltraStarCodecError: Error, Equatable, Sendable {
    /// The file has no content.
    case emptyFile
    /// C-4: timing derives from `#BPM` — without it there is no time base.
    case missingBPM
    /// `#BPM` is not a number.
    case invalidBPM(String)
    /// `#BPM` is not a positive tempo.
    case nonPositiveBPM(Double)
    /// `#GAP` is not an integer number of milliseconds.
    case invalidGAP(String)
    /// A note line starts with something that is not a known kind.
    case unknownNoteKind(String)
    /// A note line's start beat is not an integer.
    case invalidStartBeat(String)
    /// A note line's length is not an integer.
    case invalidLengthBeats(String)
    /// A note line's pitch is not an integer.
    case invalidPitch(String)
    /// A note line has too few fields.
    case malformedNoteLine(String)
}

/// The result of parsing an UltraStar `.txt` file: the track we CAN build,
/// plus an honest account of everything the format could not carry.
public struct UltraStarImportResult: Equatable, Sendable {
    /// The parsed track. `cents_ref` is 0 and `confidence` is 1.0 (C-4).
    public let track: NoteTrack
    /// The file's tempo (quarter note = 1 beat).
    public let bpm: Double
    /// The file's gap in milliseconds (file start → beat 0).
    public let gap_ms: Int
    /// `#TITLE`, if present.
    public let title: String?
    /// `#ARTIST`, if present.
    public let artist: String?
    /// Golden (`*`) notes imported as ordinary notes — C-2.3 has no golden
    /// flag, so the bonus does not survive the round-trip.
    public let goldenNoteCount: Int
    /// How many lines of each NON-pitched kind were seen (F/R/G).
    public let ignoredKindCounts: [UltraStarNoteKind: Int]
    /// Lines dropped: zero-length notes, unrepairable overlaps, malformed
    /// lines (strict mode throws instead).
    public let droppedNoteCount: Int
    /// Overlaps trimmed so the track satisfies C-2.3 V8 (sorted,
    /// non-overlapping within a part).
    public let repairedOverlapCount: Int
    /// Notes whose lyric text was dropped (no field in C-2.3).
    public let droppedLyricNoteCount: Int
    /// Human-readable notes about everything that was not a clean import.
    public let warnings: [String]

    public init(track: NoteTrack, bpm: Double, gap_ms: Int, title: String?, artist: String?,
                goldenNoteCount: Int, ignoredKindCounts: [UltraStarNoteKind: Int],
                droppedNoteCount: Int, repairedOverlapCount: Int,
                droppedLyricNoteCount: Int, warnings: [String]) {
        self.track = track
        self.bpm = bpm
        self.gap_ms = gap_ms
        self.title = title
        self.artist = artist
        self.goldenNoteCount = goldenNoteCount
        self.ignoredKindCounts = ignoredKindCounts
        self.droppedNoteCount = droppedNoteCount
        self.repairedOverlapCount = repairedOverlapCount
        self.droppedLyricNoteCount = droppedLyricNoteCount
        self.warnings = warnings
    }
}

/// The result of writing an UltraStar `.txt` file: the text, plus an honest
/// account of what the beat quantization cost.
public struct UltraStarExportResult: Equatable, Sendable {
    /// The file content.
    public let text: String
    /// Human-readable notes (clamped pitches, sub-beat notes, …).
    public let warnings: [String]
    /// The largest absolute timing change the beat quantization introduced, in
    /// seconds. A caller can show this to the user instead of implying the
    /// timing was copied exactly.
    public let maxTimingError_s: Double
    /// Notes whose MIDI pitch sat outside C-2.3's V9 range and were clamped.
    public let clampedPitchNoteCount: Int

    public init(text: String, warnings: [String], maxTimingError_s: Double,
                clampedPitchNoteCount: Int) {
        self.text = text
        self.warnings = warnings
        self.maxTimingError_s = maxTimingError_s
        self.clampedPitchNoteCount = clampedPitchNoteCount
    }
}

/// The UltraStar `.txt` codec (J-303, CONTRACTS C-4).
public enum UltraStarCodec {

    /// Default export tempo. A quarter note is one beat (C-4).
    public static let defaultBPM: Double = 120

    /// C-2.3 V9 — the MIDI range a note may occupy.
    public static let midiRange: ClosedRange<Int> = 24...96

    /// The offset between an UltraStar pitch token and a MIDI note number
    /// (C-4: "UltraStar note token pitch is MIDI − 60").
    public static let pitchOffset: Int = 60

    // MARK: - Export

    /// Write a track as an UltraStar `.txt` file.
    ///
    /// The beat grid is chosen by the caller (`bpm`); C-4 requires export to
    /// "round start_s/end_s to the nearest beat under the chosen #BPM". The
    /// endpoints are quantized INDEPENDENTLY and the length is derived from
    /// them, so a note that starts and ends on the grid round-trips exactly.
    ///
    /// - Parameters:
    ///   - track: the part track to write (one part per file).
    ///   - bpm: quarter notes per minute (the beat unit).
    ///   - gap_ms: milliseconds from the file start to beat 0.
    ///   - title: `#TITLE` (omitted when nil).
    ///   - artist: `#ARTIST` (omitted when nil).
    ///   - goldenNoteIndices: indices (into `track.notes`) to emit as `*`
    ///     (golden). C-2.3 has no golden flag, so this is out-of-band and does
    ///     not survive a round-trip.
    public static func export(track: NoteTrack,
                              bpm: Double = defaultBPM,
                              gap_ms: Int = 0,
                              title: String? = nil,
                              artist: String? = nil,
                              goldenNoteIndices: Set<Int> = []) throws -> UltraStarExportResult {
        guard bpm.isFinite, bpm > 0 else {
            throw UltraStarCodecError.nonPositiveBPM(bpm)
        }

        let gap_s = Double(gap_ms) / 1000.0
        let secondsPerBeat = 60.0 / bpm

        var warnings: [String] = []
        var maxTimingError = 0.0
        var clampedPitchCount = 0

        var lines: [String] = []
        if let title {
            lines.append("#TITLE:\(title)")
        }
        if let artist {
            lines.append("#ARTIST:\(artist)")
        }
        lines.append("#BPM:\(formatBPM(bpm))")
        lines.append("#GAP:\(gap_ms)")

        for (index, note) in track.notes.enumerated() {
            let rawStartBeat = (note.start_s - gap_s) / secondsPerBeat
            let rawEndBeat = (note.end_s - gap_s) / secondsPerBeat
            var startBeat = beatIndex(rawStartBeat)
            var endBeat = beatIndex(rawEndBeat)

            if rawStartBeat < 0 {
                warnings.append("Note \(index) starts before the gap and was moved to beat 0.")
                startBeat = 0
                endBeat = max(endBeat, startBeat)
            }

            var lengthBeats = endBeat - startBeat
            if lengthBeats < 1 {
                // A note shorter than the beat grid still needs a length the
                // format can express; one beat is the smallest.
                lengthBeats = 1
                warnings.append("Note \(index) is shorter than one beat and was exported as one beat.")
            }

            var midi = note.midi
            if !midiRange.contains(midi) {
                let clamped = min(max(midi, midiRange.lowerBound), midiRange.upperBound)
                warnings.append("Note \(index) has MIDI \(midi), outside the contract range "
                                + "\(midiRange.lowerBound)…\(midiRange.upperBound); it was written as \(clamped).")
                midi = clamped
                clampedPitchCount += 1
            }

            let kind: UltraStarNoteKind = goldenNoteIndices.contains(index) ? .golden : .normal
            lines.append("\(kind.rawValue) \(startBeat) \(lengthBeats) \(midi - pitchOffset)")

            // How much the beat grid moved this note (honesty, not decoration).
            let exportedStart = gap_s + Double(startBeat) * secondsPerBeat
            let exportedEnd = gap_s + Double(startBeat + lengthBeats) * secondsPerBeat
            maxTimingError = max(maxTimingError, abs(exportedStart - note.start_s))
            maxTimingError = max(maxTimingError, abs(exportedEnd - note.end_s))
        }

        return UltraStarExportResult(text: lines.joined(separator: "\n") + "\n",
                                     warnings: warnings,
                                     maxTimingError_s: maxTimingError,
                                     clampedPitchNoteCount: clampedPitchCount)
    }

    // MARK: - Import

    /// Parse an UltraStar `.txt` file into a track for `part`.
    ///
    /// - Parameters:
    ///   - text: the file content.
    ///   - part: the part the resulting track belongs to (C-2.3 carries one).
    ///   - strict: when true, a malformed note line throws instead of being
    ///     skipped and reported.
    public static func parse(text: String, part: Part, strict: Bool = false) throws -> UltraStarImportResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw UltraStarCodecError.emptyFile }

        var bpm: Double?
        var gap_ms = 0
        var title: String?
        var artist: String?
        var warnings: [String] = []

        var rawPitched: [(startBeat: Int, lengthBeats: Int, pitch: Int)] = []
        var ignoredKindCounts: [UltraStarNoteKind: Int] = [:]
        var goldenCount = 0
        var droppedCount = 0
        var droppedLyricCount = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("//") { continue }          // comment line

            if line.hasPrefix("#") {
                let body = line.dropFirst()
                let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }    // unknown header → ignored
                let key = parts[0].trimmingCharacters(in: .whitespaces).uppercased()
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                switch key {
                case "BPM":
                    guard let parsed = Double(value) else { throw UltraStarCodecError.invalidBPM(value) }
                    guard parsed > 0 else { throw UltraStarCodecError.nonPositiveBPM(parsed) }
                    bpm = parsed
                case "GAP":
                    guard let parsed = Int(value) else { throw UltraStarCodecError.invalidGAP(value) }
                    gap_ms = parsed
                case "TITLE":
                    title = value.isEmpty ? nil : value
                case "ARTIST":
                    artist = value.isEmpty ? nil : value
                default:
                    break                               // #MP3, #YEAR, … are not ours
                }
                continue
            }

            // A note line: `<kind> <start beat> <length beats> <pitch> [lyric]`.
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard tokens.count >= 4 else {
                if strict { throw UltraStarCodecError.malformedNoteLine(line) }
                droppedCount += 1
                warnings.append("Ignored a note line with too few fields: \(line)")
                continue
            }

            let kindToken = String(tokens[0])
            guard let kind = UltraStarNoteKind(rawValue: kindToken) else {
                if strict { throw UltraStarCodecError.unknownNoteKind(kindToken) }
                droppedCount += 1
                warnings.append("Ignored a note line with an unknown kind '\(kindToken)'.")
                continue
            }

            guard let startBeat = Int(tokens[1]) else {
                if strict { throw UltraStarCodecError.invalidStartBeat(String(tokens[1])) }
                droppedCount += 1
                warnings.append("Ignored a note line with a non-integer start beat: \(line)")
                continue
            }
            guard let lengthBeats = Int(tokens[2]) else {
                if strict { throw UltraStarCodecError.invalidLengthBeats(String(tokens[2])) }
                droppedCount += 1
                warnings.append("Ignored a note line with a non-integer length: \(line)")
                continue
            }
            guard let pitch = Int(tokens[3]) else {
                if strict { throw UltraStarCodecError.invalidPitch(String(tokens[3])) }
                droppedCount += 1
                warnings.append("Ignored a note line with a non-integer pitch: \(line)")
                continue
            }

            if tokens.count > 4 {
                droppedLyricCount += 1
            }

            guard kind.isPitched else {
                // F / R / G have no definite pitch in the C-4 mapping.
                ignoredKindCounts[kind, default: 0] += 1
                continue
            }

            if kind == .golden { goldenCount += 1 }

            guard lengthBeats > 0 else {
                droppedCount += 1
                warnings.append("Ignored a zero-length note at beat \(startBeat).")
                continue
            }

            // The note's TIMES are computed after the whole file is read, so a
            // `#BPM`/`#GAP` header that appears after the notes still governs
            // them (C-4: timing derives from #BPM and #GAP).
            rawPitched.append((startBeat: startBeat, lengthBeats: lengthBeats, pitch: pitch))
        }

        guard let resolvedBPM = bpm else { throw UltraStarCodecError.missingBPM }

        let secondsPerBeat = 60.0 / resolvedBPM
        let gap_s = Double(gap_ms) / 1000.0
        var pitched: [Note] = []
        for raw in rawPitched {
            let start_s = gap_s + Double(raw.startBeat) * secondsPerBeat
            let end_s = gap_s + Double(raw.startBeat + raw.lengthBeats) * secondsPerBeat

            var midi = raw.pitch + pitchOffset
            if !midiRange.contains(midi) {
                let clamped = min(max(midi, midiRange.lowerBound), midiRange.upperBound)
                warnings.append("A note at UltraStar pitch \(raw.pitch) (MIDI \(midi)) is outside the contract "
                                + "range \(midiRange.lowerBound)…\(midiRange.upperBound); it was read as \(clamped).")
                midi = clamped
            }

            // C-4: UltraStar cannot carry cents_ref or confidence.
            pitched.append(Note(start_s: start_s, end_s: end_s, midi: midi,
                                cents_ref: 0, confidence: 1.0))
        }

        // C-2.3 V8: sorted by start_s, non-overlapping within a part.
        pitched.sort { lhs, rhs in
            if lhs.start_s != rhs.start_s { return lhs.start_s < rhs.start_s }
            if lhs.end_s != rhs.end_s { return lhs.end_s < rhs.end_s }
            return lhs.midi < rhs.midi
        }

        var repaired = 0
        var repairedNotes: [Note] = []
        for note in pitched {
            if let last = repairedNotes.last, note.start_s < last.end_s {
                let trimmed = Note(start_s: last.start_s, end_s: note.start_s, midi: last.midi,
                                   cents_ref: last.cents_ref, confidence: last.confidence)
                if trimmed.end_s > trimmed.start_s {
                    repairedNotes[repairedNotes.count - 1] = trimmed
                    repaired += 1
                } else {
                    droppedCount += 1
                    warnings.append("Dropped a note that starts at the same instant as the previous one "
                                    + "and overlaps it.")
                    continue
                }
            }
            repairedNotes.append(note)
        }

        if repaired > 0 {
            warnings.append("Trimmed \(repaired) overlapping note(s) so the track satisfies C-2.3 V8.")
        }
        if droppedLyricCount > 0 {
            warnings.append("Dropped lyric text on \(droppedLyricCount) note(s): the note track has no lyric field.")
        }
        if !ignoredKindCounts.isEmpty {
            let summary = ignoredKindCounts
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.value)×\($0.key.rawValue)" }
                .joined(separator: ", ")
            warnings.append("Accepted but did not map \(summary) line(s) to notes: those kinds carry no definite pitch.")
        }

        let track = NoteTrack(contractVersion: NoteTrack.currentContractVersion,
                              part: part, notes: repairedNotes)
        return UltraStarImportResult(track: track,
                                     bpm: resolvedBPM,
                                     gap_ms: gap_ms,
                                     title: title,
                                     artist: artist,
                                     goldenNoteCount: goldenCount,
                                     ignoredKindCounts: ignoredKindCounts,
                                     droppedNoteCount: droppedCount,
                                     repairedOverlapCount: repaired,
                                     droppedLyricNoteCount: droppedLyricCount,
                                     warnings: warnings)
    }

    // MARK: - Helpers

    /// A safe Double → Int beat index (never traps on NaN/infinity/huge).
    private static func beatIndex(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        let rounded = value.rounded()
        guard rounded < 1_000_000 else { return 1_000_000 }
        guard rounded > -1_000_000 else { return -1_000_000 }
        return Int(rounded)
    }

    /// `#BPM` formatting: an integer tempo prints as an integer (players are
    /// happier with "120" than "120.0"), anything else keeps its fraction.
    private static func formatBPM(_ bpm: Double) -> String {
        let rounded = bpm.rounded()
        if abs(bpm - rounded) < 1e-9, abs(rounded) < 1e15 {
            return String(Int(rounded))
        }
        return String(bpm)
    }
}
