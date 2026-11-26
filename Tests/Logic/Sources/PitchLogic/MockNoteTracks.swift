// MockNoteTracks — the MOCK NoteTrack source J-301 renders until Paul's
// P-305 lands the real per-part tracks (AGENTS §10 step 3: build against a
// MOCK, never block on the engine; the swap must be ZERO UI changes).
//
// HONESTY: these tracks are SYNTHETIC. They are not a transcription, not a
// measurement, and not a claim about any recording. The UI labels every
// mock-sourced roll as a demo ("mock track — not a real import"), and the
// real-track path renders the SAME view with the SAME input type
// (`[Part: NoteTrack]`), so the swap touches no view code.
//
// The fixture deliberately exercises the rules the roll must show:
//   · all three D-41 confidence bands (confirmed / provisional / unassigned),
//   · a part that is ABSENT in some phrases (dimmed, never hidden — D-41 §2),
//   · a UNISON passage (two parts on the same pitch — D-41 §3 → badge),
//   · a multi-minute song (the 4-minute smoothness target).

import Foundation
import EngineCore

public enum MockNoteTracks {

    /// The five male-voice parts of an SDA chart, C-1 display order.
    public static let maleParts: [Part] = [.t1, .t2, .baritenor, .baritone, .bass]

    // MARK: - The demo roll (short, readable)

    /// A deterministic 24-second, five-part demo roll.
    ///
    /// Structure (4.0 s phrases, D-41 §2):
    ///   phrase 0 — all five parts, confirmed confidence (0.92)
    ///   phrase 1 — T2 is silent (the part reads ABSENT → dimmed)
    ///   phrase 2 — T1 and T2 sing the SAME pitch (unison passage, badge)
    ///   phrase 3 — low confidence everywhere (provisional / unassigned bands)
    ///   phrase 4 — bass drops out (absent) while the upper parts continue
    ///   phrase 5 — all five parts, confirmed
    public static func demoTracks(duration_s: Double = 24.0) -> [Part: NoteTrack] {
        var tracks: [Part: NoteTrack] = [:]
        for part in maleParts {
            tracks[part] = NoteTrack(part: part, notes: demoNotes(for: part))
        }
        return tracks
    }

    /// The demo roll's duration (the view needs it for the scroll extent).
    public static let demoDuration_s: Double = 24.0

    private static func demoNotes(for part: Part) -> [Note] {
        var notes: [Note] = []
        let phrase = PianoRollModel.phraseDuration_s

        // phrase 0 — a clean C-major-ish stack, confirmed.
        notes += chordNotes(part: part, phraseStart: 0, confidence: 0.92, midiOffset: 0)
        // phrase 1 — T2 is silent (absent part).
        if part != .t2 {
            notes += chordNotes(part: part, phraseStart: phrase, confidence: 0.88, midiOffset: 2)
        }
        // phrase 2 — UNISON: T1 and T2 both sing MIDI 62 (D4).
        if part == .t1 || part == .t2 {
            notes.append(Note(start_s: phrase * 2 + 0.5, end_s: phrase * 2 + 2.5,
                              midi: 62, cents_ref: 4, confidence: 0.75))
        } else {
            notes += chordNotes(part: part, phraseStart: phrase * 2, confidence: 0.81, midiOffset: -3)
        }
        // phrase 3 — soft assignment: provisional + unassigned bands.
        let soft: Double = (part == .baritenor) ? 0.35 : 0.62
        notes += chordNotes(part: part, phraseStart: phrase * 3, confidence: soft, midiOffset: 0)
        // phrase 4 — the bass drops out (absent part).
        if part != .bass {
            notes += chordNotes(part: part, phraseStart: phrase * 4, confidence: 0.90, midiOffset: 4)
        }
        // phrase 5 — back to confirmed.
        notes += chordNotes(part: part, phraseStart: phrase * 5, confidence: 0.95, midiOffset: -2)
        return notes
    }

    /// Two notes per part per phrase (a simple, readable chart).
    private static func chordNotes(part: Part, phraseStart: Double, confidence: Double,
                                   midiOffset: Int) -> [Note] {
        let base: Int
        switch part {
        case .t1: base = 72
        case .t2: base = 67
        case .baritenor: base = 62
        case .baritone: base = 57
        case .bass: base = 48
        default: base = 60
        }
        let first = base + midiOffset
        let second = base + midiOffset + (part == .bass ? 7 : 5)
        return [
            Note(start_s: phraseStart + 0.2, end_s: phraseStart + 1.9,
                 midi: first, cents_ref: 0, confidence: confidence),
            Note(start_s: phraseStart + 2.1, end_s: phraseStart + 3.8,
                 midi: second, cents_ref: 6, confidence: max(confidence - 0.04, 0))
        ]
    }

    // MARK: - The performance fixture (4 minutes)

    /// A deterministic FOUR-MINUTE, five-part roll — the J-301 smoothness
    /// target ("smooth on a 4-min song"). ~2 notes per part per 4 s phrase,
    /// i.e. ~600 notes per part, ~3000 notes in total: the roll must cull to
    /// the visible window and must not rebuild per frame.
    public static func longSongTracks(duration_s: Double = 240.0) -> [Part: NoteTrack] {
        var tracks: [Part: NoteTrack] = [:]
        for part in maleParts {
            var notes: [Note] = []
            let phrase = PianoRollModel.phraseDuration_s
            var phraseIndex = 0
            var t = 0.0
            while t < duration_s {
                // Deterministic pseudo-random-ish variation WITHOUT a random
                // source: a cheap LCG so the fixture is byte-identical on every
                // platform and every CI run.
                let seed = UInt64(phraseIndex) &* 2_654_435_761 &+ UInt64(part.sortOrder) &* 97
                let jitter = Double(Int(seed % 5) - 2)          // −2…+2 semitones
                let confidence = 0.55 + Double((seed >> 3) % 45) / 100.0  // 0.55…0.99
                let base: Int
                switch part {
                case .t1: base = 72
                case .t2: base = 67
                case .baritenor: base = 62
                case .baritone: base = 57
                default: base = 48
                }
                let midi = min(max(base + Int(jitter), 36), 79)
                // Four notes per phrase (a busier chart than the demo) so the
                // fixture really exercises the culling path.
                notes.append(Note(start_s: t + 0.10, end_s: t + 0.90,
                                  midi: midi, cents_ref: Int((seed >> 8) % 21) - 10,
                                  confidence: confidence))
                notes.append(Note(start_s: t + 1.00, end_s: t + 1.85,
                                  midi: midi + 5, cents_ref: Int((seed >> 12) % 21) - 10,
                                  confidence: max(confidence - 0.03, 0)))
                notes.append(Note(start_s: t + 2.00, end_s: t + 2.90,
                                  midi: midi + 7, cents_ref: Int((seed >> 16) % 21) - 10,
                                  confidence: max(confidence - 0.06, 0)))
                notes.append(Note(start_s: t + 3.00, end_s: t + 3.90,
                                  midi: midi + 12, cents_ref: Int((seed >> 20) % 21) - 10,
                                  confidence: max(confidence - 0.08, 0)))
                t += phrase
                phraseIndex += 1
            }
            tracks[part] = NoteTrack(part: part, notes: notes)
        }
        return tracks
    }

    /// The long-song fixture's duration.
    public static let longSongDuration_s: Double = 240.0
}
