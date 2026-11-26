import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// P-304 · The MusicXML parser — THE ONE PARSER (D-40 §1).
//
// WHAT THIS IS: a MINIMAL, NOTE-EVENTS-ONLY MusicXML reader built on
// Foundation's `XMLParser`. It lives in the PORTABLE engine core (no UIKit,
// no SwiftUI, no AVFoundation), so `pitchnotes-ios`, `-android` and `-linux`
// share it unchanged (AGENTS §0). **NO new dependency** — D-40 §1 rules out
// libxml and every MusicXML library.
//
// THE SCOPE (D-40 §2, verbatim):
//   · IN: `<score-partwise>`; per `<part>` the `<measure>` index; per `<note>`
//     `<pitch>` (step + alter + octave → MIDI), `<duration>` (in `<divisions>`
//     units) and `<voice>`; a `<rest>` is SKIPPED but advances the timeline;
//     `<part-list>/<score-part>/<part-name>` gives the label; a mid-part
//     `<divisions>` change is honoured.
//   · OUT: `<score-timewise>` (REJECTED with an honest error), engraving and
//     layout (`<print>`, `<defaults>`), `<direction>`/lyrics text, harmony and
//     chord symbols, `<backup>` handling beyond a linear timeline, MusicXML
//     4.0 extensions.
//   · **A file that uses only excluded features yields an EMPTY score plus an
//     honest "no note events parsed" notice — never a crash, never a failed
//     import.**
//
// THE PARSER NEVER ALIGNS BY ITSELF (D-40 §5): parsing and alignment are
// SEPARATE steps, and only the alignment produces C-13.2. This file produces
// C-13.1 and nothing else.
//
// THE TIMELINE: the cursor is kept in SECONDS, and every duration is
// converted with the `<divisions>` value IN EFFECT AT THAT MOMENT — so a
// mid-part `<divisions>` change is honoured exactly, and `<backup>`/`<forward>`
// move the cursor back and forth on the same linear timeline (the scope's
// "linear timeline" rule). The voices are RECORDED per note (C-13.1's
// `voice`), but the timeline is per part: two voices inside one part are not
// independently timed (that is the part of the spec D-40 puts out of scope).
//
// THE TEMPO: the score's own tempo, from `<sound tempo="…"/>`. With no tempo
// declared the MusicXML default (120 BPM ⇒ a quarter = 0.5 s) applies. The
// times in the score-note list are at THIS tempo, BEFORE any alignment
// (C-13.1's rule).

// MARK: - The result

/// What the parser produced: the contract's score-note list PLUS the things
/// C-13.1 has no field for (the part labels and the honest notices).
public struct ParsedMusicXMLScore: Equatable, Sendable {
    /// The contract's score-note list (C-13.1).
    public var noteList: ScoreContract.NoteList
    /// The score's own part identifier → its `<part-name>` label.
    ///
    /// The label is what the alignment uses to map a score part onto a C-1
    /// part — an EXPLICIT, name-based correspondence, never a guess from the
    /// pitches (D-47 §8).
    public var partLabels: [String: String]
    /// The score's own tempo (BPM). 120 when the file declares none.
    public var tempoBPM: Double
    /// The `<divisions>` value in effect at the END of the file (the value is
    /// per measure; this is the last one seen).
    public var divisionsPerQuarter: Int
    /// The honest notices: what was ignored, and why the score is empty.
    public var notices: [String]

    public init(noteList: ScoreContract.NoteList,
                partLabels: [String: String],
                tempoBPM: Double,
                divisionsPerQuarter: Int,
                notices: [String]) {
        self.noteList = noteList
        self.partLabels = partLabels
        self.tempoBPM = tempoBPM
        self.divisionsPerQuarter = divisionsPerQuarter
        self.notices = notices
    }

    /// The score's own duration in seconds.
    public var duration: Double { noteList.duration }
}

// MARK: - The errors

/// Why a score could not be parsed.
public enum MusicXMLScoreError: Error, Equatable {
    /// The file is not a MusicXML document this parser can read.
    case malformedScore(String)
    /// The document is well-formed MusicXML but OUT of the parser's scope
    /// (D-40 §2) — e.g. `<score-timewise>`.
    case unsupportedDocument(String)
}

// MARK: - The parser

/// The ONE MusicXML parser (D-40 §1).
public enum MusicXMLScoreParser {

    /// Parse a MusicXML file into the contract's score-note list (C-13.1).
    ///
    /// - Throws: `MusicXMLScoreError.malformedScore` for a file that is not
    ///   parseable MusicXML, `.unsupportedDocument` for `<score-timewise>`.
    ///   A file that parses but carries no note events is NOT an error: it
    ///   yields an EMPTY list plus a notice (D-40 §2).
    public static func parse(data: Data) throws -> ParsedMusicXMLScore {
        let delegate = MusicXMLScoreParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        let ok = parser.parse()
        if let unsupported = delegate.unsupportedReason {
            throw MusicXMLScoreError.unsupportedDocument(unsupported)
        }
        if !ok, let reason = delegate.failureReason {
            throw MusicXMLScoreError.malformedScore(reason)
        }
        return delegate.result()
    }

    /// Parse a MusicXML file from disk.
    public static func parse(contentsOf url: URL) throws -> ParsedMusicXMLScore {
        let data = try Data(contentsOf: url)
        return try parse(data: data)
    }
}

// MARK: - The delegate

/// The `XMLParser` delegate that does the actual reading.
final class MusicXMLScoreParserDelegate: NSObject, XMLParserDelegate {

    // MARK: The output

    private(set) var notes: [ScoreContract.Note] = []
    private(set) var labels: [String: String] = [:]
    private(set) var notices: [String] = []
    private(set) var unsupportedReason: String?
    private(set) var failureReason: String?

    private var rootElement: String?
    private var ignoredCounts: [String: Int] = [:]

    // MARK: The timeline state

    private var currentPartID: String?
    private var currentScorePartID: String?
    private var currentMeasure = 0
    private var measureCounter = 0
    private var divisions = 1.0
    private var cursorSeconds = 0.0
    private var secondsPerQuarter = 0.5
    private var tempoBPM = 120.0

    // MARK: The note state

    private var inNote = false
    private var noteStep: String?
    private var noteAlter = 0
    private var noteOctave: Int?
    private var noteDuration: Double?
    private var noteVoice = 1
    private var noteIsRest = false
    private var noteIsChord = false
    private var noteIsGrace = false
    private var previousNoteStart: Double?

    // MARK: The `<backup>` / `<forward>` state

    private var inBackup = false
    private var inForward = false
    private var skipDuration = 0.0

    // MARK: The text buffer

    private var text = ""

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        text = ""
        switch elementName {
        case "score-partwise":
            if rootElement == nil { rootElement = elementName }
        case "score-timewise":
            unsupportedReason = ("<score-timewise> is out of the parser's scope — only "
                                 + "<score-partwise> is supported (D-40 §2).")
            parser.abortParsing()
        case "score-part":
            currentScorePartID = attributeDict["id"]
        case "part":
            currentPartID = attributeDict["id"]
            cursorSeconds = 0
            measureCounter = 0
            divisions = 1
            previousNoteStart = nil
        case "measure":
            if let number = attributeDict["number"], let parsed = Int(number.trimmingCharacters(in: .whitespaces)) {
                currentMeasure = parsed
            } else {
                measureCounter += 1
                currentMeasure = measureCounter
            }
        case "sound":
            if let tempo = attributeDict["tempo"], let value = Double(tempo), value > 0 {
                tempoBPM = value
                secondsPerQuarter = 60.0 / value
            }
        case "note":
            inNote = true
            noteStep = nil
            noteAlter = 0
            noteOctave = nil
            noteDuration = nil
            noteVoice = 1
            noteIsRest = false
            noteIsChord = false
            noteIsGrace = false
        case "rest":
            if inNote { noteIsRest = true }
        case "chord":
            if inNote { noteIsChord = true }
        case "grace":
            if inNote { noteIsGrace = true }
        case "backup":
            inBackup = true
            skipDuration = 0
        case "forward":
            inForward = true
            skipDuration = 0
        case "direction", "print", "defaults", "harmony", "lyric", "metronome":
            ignoredCounts[elementName, default: 0] += 1
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        switch elementName {
        case "part-name":
            if let id = currentScorePartID, !trimmed.isEmpty { labels[id] = trimmed }
        case "divisions":
            if let value = Double(trimmed), value > 0 { divisions = value }
        case "step":
            if inNote { noteStep = trimmed }
        case "alter":
            if inNote { noteAlter = Int(trimmed) ?? 0 }
        case "octave":
            if inNote { noteOctave = Int(trimmed) }
        case "duration":
            if inBackup || inForward {
                skipDuration = Double(trimmed) ?? 0
            } else if inNote {
                noteDuration = Double(trimmed)
            }
        case "voice":
            if inNote { noteVoice = Int(trimmed) ?? 1 }
        case "note":
            finishNote()
        case "backup":
            cursorSeconds -= skipDuration / max(1, divisions) * secondsPerQuarter
            inBackup = false
        case "forward":
            cursorSeconds += skipDuration / max(1, divisions) * secondsPerQuarter
            inForward = false
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        // The cancellation error is the one `abortParsing()` raises — it is
        // already reported through `unsupportedReason`.
        //
        // The domain and the code are SPELLED OUT (not taken from the
        // `NSXMLParserErrorDomain` / `NSXMLParserCancelledError` constants):
        // those constants live in `Foundation` on Apple platforms and in
        // `FoundationXML` on Linux, and the literals are the same on both.
        let nsError = parseError as NSError
        guard nsError.domain == "NSXMLParserErrorDomain", nsError.code == 512 else {
            failureReason = parseError.localizedDescription
            return
        }
    }

    // MARK: - The result

    func result() -> ParsedMusicXMLScore {
        var notices = self.notices
        for (element, count) in ignoredCounts.sorted(by: { $0.key < $1.key }) {
            notices.append("Ignored \(count) <\(element)> element(s) — outside the parser's note-event scope (D-40 §2).")
        }
        if notes.isEmpty {
            notices.append("No note events parsed — the score carries only features outside the parser's scope (D-40 §2).")
        }
        if let rootElement, rootElement != "score-partwise" {
            notices.append("The document's root element is <\(rootElement)>, not <score-partwise>.")
        }
        return ParsedMusicXMLScore(
            noteList: ScoreContract.NoteList(scoreNotes: notes),
            partLabels: labels,
            tempoBPM: tempoBPM,
            divisionsPerQuarter: Int(divisions.rounded()),
            notices: notices)
    }

    // MARK: - One note

    private func finishNote() {
        defer { inNote = false }
        let durationDivisions = noteDuration ?? 0
        let durationSeconds = durationDivisions / max(1, divisions) * secondsPerQuarter

        // A grace note has no duration of its own (out of scope — it is
        // skipped, and it does not move the timeline).
        if noteIsGrace { return }

        if noteIsRest {
            // A rest is SKIPPED but ADVANCES the timeline (D-40 §2).
            if !noteIsChord { cursorSeconds += durationSeconds }
            return
        }

        guard let step = noteStep, let octave = noteOctave,
              let midi = MusicXMLPitch.midi(step: step, alter: noteAlter, octave: octave) else {
            return
        }
        guard durationSeconds > 0 else { return }

        let start: Double
        if noteIsChord, let previousStart = previousNoteStart {
            start = previousStart
        } else {
            start = cursorSeconds
        }
        let end = start + durationSeconds

        notes.append(ScoreContract.Note(midi: midi,
                                        start_s: start,
                                        end_s: end,
                                        measure: max(1, currentMeasure),
                                        part_id: currentPartID ?? "P1",
                                        voice: max(1, noteVoice)))
        previousNoteStart = start
        if !noteIsChord { cursorSeconds += durationSeconds }
    }
}

// MARK: - The pitch spelling

/// The pitch spelling → MIDI conversion (step + alter + octave).
public enum MusicXMLPitch {

    /// The diatonic step's semitone offset.
    private static let stepSemitones: [String: Int] = [
        "C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11
    ]

    /// The MIDI note number for a spelled pitch.
    ///
    /// `midi = (octave + 1) * 12 + step + alter` — C4 = 60 (A440, equal
    /// temperament). `nil` for an unknown step or an octave outside 0…9.
    public static func midi(step: String, alter: Int, octave: Int) -> Int? {
        guard let base = stepSemitones[step.uppercased()] else { return nil }
        guard (0...9).contains(octave) else { return nil }
        return (octave + 1) * 12 + base + alter
    }
}
