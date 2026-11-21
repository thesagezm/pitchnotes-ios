// PitchMath — pitch/cents math helpers for UI and grading (Jess's lane per
// AGENTS §1: "pitch/cents math helpers for UI and grading" are Jess-owned).
// Reference: CONTRACTS v0.0 C-2.3 (midi/cents_ref semantics), Docs/UX.md §3.3
// (ribbon mapping), Docs/RESEARCH.md §4d (grading math).
//
// Pure Foundation; runs in `swift test` on CI (logic-tests) with no audio
// hardware. The ribbon's vertical mapping (UX §3.3) is linear in cents, which
// is exactly what `cents(from:to:)` produces.

import Foundation

public enum PitchMath {

    // MARK: - Core conversion (RESEARCH §4d: cents = 1200·log2(f_user/f_ref))

    /// Cents from frequency `from` to frequency `to` (+ = sharper than `from`).
    /// Both must be > 0.
    public static func cents(from: Double, to: Double) -> Double {
        precondition(from > 0 && to > 0, "frequencies must be positive")
        return 1200 * log2(to / from)
    }

    /// Equal-tempered frequency for a MIDI note number (A4 = MIDI 69 = 440 Hz,
    /// C4 = MIDI 60 — CONTRACTS C-2.3 semantics).
    public static func hz(forMidi midi: Int) -> Double {
        440.0 * pow(2.0, (Double(midi) - 69.0) / 12.0)
    }

    /// Nearest equal-tempered MIDI note for a frequency; `nil` for unvoiced
    /// input (hz ≤ 0 — CONTRACTS C-2.4: hz == 0.0 means unvoiced).
    public static func midiNearest(forHz hz: Double) -> Int? {
        guard hz > 0 else { return nil }
        let midi = 69.0 + 12.0 * log2(hz / 440.0)
        return Int(midi.rounded(.toNearestOrAwayFromZero))
    }

    /// Deviation of a frequency from the equal-tempered center of `midi`,
    /// in cents (+ = sharper). Matches C-2.3 `cents_ref` semantics before
    /// clamping; callers writing NoteTracks clamp to [-50, +50] per V9.
    /// (`Self.hz` — the `hz` parameter shadows the function name.)
    public static func centsRef(hz: Double, midi: Int) -> Double {
        cents(from: Self.hz(forMidi: midi), to: hz)
    }

    // MARK: - Octave-equivalence folding (C-5 default ON; UX §3.5)

    /// Fold a cents deviation into [-600, +600) by removing whole octaves.
    /// A singer exactly an octave off folds to 0 — the ribbon then shows the
    /// octave badge (UX §3.5) and grading decides per its octave toggle.
    public static func foldedCents(_ cents: Double) -> Double {
        cents - 1200 * (cents / 1200).rounded(.toNearestOrAwayFromZero)
    }

    /// True when the deviation is octave-shaped: folds in-tune but is outside
    /// the semitone itself (drives the UX §3.4 `octaveError` state).
    public static func isOctaveError(_ cents: Double, tolerance: Double = 50) -> Bool {
        abs(foldedCents(cents)) <= tolerance && abs(cents) > tolerance
    }

    // MARK: - Note names (scientific pitch notation, C4 = MIDI 60)

    /// "C4", "A4", "E2"… sharps preferred by default. MIDI range 24–96 per V9
    /// but the mapping itself is total (0–127).
    public static func noteName(forMidi midi: Int, preferFlats: Bool = false) -> String {
        let sharpNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        let flatNames = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]
        let names = preferFlats ? flatNames : sharpNames
        let octave = midi / 12 - 1
        return "\(names[midi % 12])\(octave)"
    }
}
