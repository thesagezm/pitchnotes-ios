// MockScore — the SYNTHETIC score + alignment J-304's demo entry uses until
// Paul's P-304 (the real MusicXML parser + aligner) lands.
//
// HONESTY (AGENTS §11 — a product requirement):
//   · this is NOT a real MusicXML score and NOT a real alignment — it is
//     built FROM the synthetic demo tracks, and the UI labels it "DEMO";
//   · it is NOT presented as the result of parsing a file: no file was
//     parsed, and the aligner's `used` flag is `false`;
//   · the real path (the `ScoreImportService` seam) is the only path that can
//     ever claim a real score.
//
// WHY IT EXISTS: the review UI (accept / reject / nudge / the C-14 decision)
// has to be demonstrable — and testable — BEFORE the parser lands. The logic
// under test is the CONSUMER's logic, and the consumer is what J-304 owns.
//
// THE STORY THE FIXTURE TELLS: the score is written at a 10 % faster tempo
// than the recording (0.90× the audio's times), so the RAW score agrees only
// PARTIALLY with the detected notes (the later phrases are shifted by more
// than a note length plus the match tolerance), and the BAR-MAP alignment
// fixes it. That is exactly the improvement D-41 §4's second condition asks
// about — so the demo shows a real before/after difference instead of a
// staged one. (At 0.96× the shift stays UNDER the note length + tolerance
// for every phrase, the raw score agrees perfectly, and there is nothing to
// improve — hence 0.90.)

import Foundation
import EngineCore

public enum MockScore {

    /// The score's own tempo factor against the demo recording (the score is
    /// 10 % faster — the audio would have to be stretched to match it).
    public static let demoTempoFactor: Double = 0.90

    /// The demo's measure length in AUDIO seconds (the demo's phrases).
    public static let demoMeasure_s: Double = 4.0

    /// The score's part identifiers (the score does NOT know our part naming —
    /// C-13.1: `part_id` is the score's own identifier).
    public static let demoPartIDs: [Part: String] = [
        .t1: "P1", .t2: "P2", .baritenor: "P3", .baritone: "P4", .bass: "P5"
    ]

    /// The DEMO score-note list (C-13.1) — the synthetic score, in the
    /// score's own (faster) timeline.
    public static func demoScore(detected: [Part: NoteTrack] = MockNoteTracks.demoTracks())
        -> ScoreNoteList {
        var notes: [ScoreNote] = []
        for part in MockNoteTracks.maleParts {
            guard let partID = demoPartIDs[part], let track = detected[part] else { continue }
            for note in track.notes {
                notes.append(ScoreNote(
                    midi: note.midi,
                    start_s: note.start_s * demoTempoFactor,
                    end_s: note.end_s * demoTempoFactor,
                    measure: Int(note.start_s / demoMeasure_s) + 1,
                    part_id: partID,
                    voice: 1))
            }
        }
        return ScoreNoteList(scoreNotes: notes)
    }

    /// The DEMO alignment (C-13.2) — the bar map, plus the part mapping.
    ///
    /// The bar map is the demo recording's phrases (4 s each) and the mapping
    /// is the score's own part identifiers → the C-1 parts. `used` is FALSE
    /// because no aligner applied anything — accepting the alignment is the
    /// USER's decision, and the UI says so.
    public static func demoAlignment(detected: [Part: NoteTrack] = MockNoteTracks.demoTracks())
        -> ScoreAlignmentResult {
        var barMap: [BarMapEntry] = []
        let duration = detected.values.flatMap(\.notes).map(\.end_s).max() ?? 0
        var measure = 1
        var start = 0.0
        while start < duration {
            barMap.append(BarMapEntry(measure: measure,
                                      start_s: start,
                                      end_s: start + demoMeasure_s))
            start += demoMeasure_s
            measure += 1
        }
        let alignment = ScoreAlignment(confidence: 0.82, used: false,
                                       barMap: barMap, method: "DEMO")
        let mapping = demoPartIDs.reduce(into: [String: Part]()) { result, pair in
            result[pair.value] = pair.key
        }
        return ScoreAlignmentResult(alignment: alignment, partMapping: mapping)
    }

    /// The whole DEMO review — score + alignment + the demo's detected tracks.
    public static func demoReview(detected: [Part: NoteTrack] = MockNoteTracks.demoTracks())
        -> ScoreReview {
        ScoreReview(score: demoScore(detected: detected),
                    alignmentResult: demoAlignment(detected: detected),
                    detected: detected,
                    hasOverlay: false)
    }
}
