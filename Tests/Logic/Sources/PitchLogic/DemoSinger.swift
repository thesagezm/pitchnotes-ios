import Foundation
import EngineCore

// DemoSinger (J-402) — the SYNTHETIC performer behind the demo session path.
//
// HONESTY (AGENTS §11 / D-54 §5): this is NOT a singer, NOT a measurement,
// and NOT a transcription. It deterministically renders a NoteTrack as the
// PitchFrame stream a PERFECT singer of that reference would produce —
// reference pitch, always voiced on the notes, silent in the gaps — so the
// demo exercises the full session path (count-in → markers → grade) with a
// known-true input. Every UI surface that shows its result labels it DEMO.
//
// The frames are tagged engine_id "DEMO_SYNTH" — a string outside the
// C-2.4 PitchEngineID enum ON PURPOSE: no real engine may ever be credited
// with a synthetic stream, and nothing downstream switches on it.
//
// CLOCK CONTRACT (the J-402 session clock): frames are stamped on the
// SESSION-LOCAL grid — t = seconds since the run started, advancing only
// while the session is un-paused. The reference begins at t = countIn_s
// (the count-in's beats are 1 s each — the session ticker's convention),
// so a note's rendered span is [countIn_s + start', countIn_s + end')
// with start'/end' the C-20 transformed times.
public enum DemoSinger {

    /// The synthetic performer's frame tag (never a PitchEngineID rawValue).
    public static let engineID = "DEMO_SYNTH"

    /// The demo singer's voicing loudness (comfortably above every
    /// reasonable breath gate; C-19's `breathGate_db` default is −60).
    public static let voicedLoudness_db = -20.0
    /// The demo singer's confidence (high but not perfect 1.0).
    public static let voicedConfidence = 0.95

    /// Renders `reference` as the session-local frame stream of a perfect
    /// singer, over `[0, sessionEnd_s)` on the 16 ms hop grid.
    ///
    /// - Parameters:
    ///   - reference: the COMPOSED grading reference (already through C-14).
    ///   - environment: the C-20 view (transposition/tempo/tuning apply to
    ///     the rendered pitch and the transformed spans).
    ///   - countIn_s: the reference's start moment in session-local time.
    ///   - sessionEnd_s: where the stream stops (the tail included).
    public static func frames(for reference: NoteTrack,
                              environment: SessionEnvironment,
                              countIn_s: Double,
                              sessionEnd_s: Double) -> [PitchFrame] {
        let hop = SessionGrader.hop_s
        guard hop > 0, sessionEnd_s > 0 else { return [] }
        let notes = reference.notes
            .map { note in
                let span = environment.transformedSpan(start_s: note.start_s,
                                                       end_s: note.end_s)
                return (start: countIn_s + span.start,
                        end: countIn_s + span.end,
                        hz: environment.referenceHz(midi: note.midi,
                                                    cents_ref: note.cents_ref))
            }
            .sorted { $0.start < $1.start }

        var frames: [PitchFrame] = []
        var t = 0.0
        while t < sessionEnd_s - 1e-9 {
            // Voiced iff inside a note's rendered span (the demo singer never
            // sings between notes and never overlaps two — spans come from
            // one track, whose notes do not overlap; ties resolve to voiced).
            var hz = 0.0
            var loudness = -120.0
            var confidence = 0.0
            for note in notes where t >= note.start - 1e-9 && t < note.end - 1e-9 {
                hz = note.hz
                loudness = voicedLoudness_db
                confidence = voicedConfidence
                break
            }
            frames.append(PitchFrame(t: t, hz: hz, confidence: confidence,
                                     loudness_db: loudness,
                                     engine_id: Self.engineID, lookahead_ms: 0))
            t += hop
        }
        return frames
    }

    /// The whole rendered performance's end in session-local time: the last
    /// note's end + the §5.4 tail. Drives the producer's stream length AND
    /// the tail deadline the model schedules.
    public static func sessionEnd_s(for reference: NoteTrack,
                                    environment: SessionEnvironment,
                                    countIn_s: Double,
                                    tail_s: Double) -> Double {
        let last = reference.notes.map {
            environment.transformedTime($0.end_s)
        }.max() ?? 0
        return countIn_s + last + tail_s
    }
}
