// RibbonMapping — the PURE cents→UI mapping behind J-101 (Docs/UX.md §3.3–§3.5).
// Every state in the UX §3.4 table is decided here, unit-tested in logic-tests;
// the SwiftUI layer only renders a `RibbonReading`. This is the file that makes
// "swaps to the real engine with ZERO UI changes" true: mapping never sees the
// engine, only contract PitchFrame values.
//
// Reference semantics: with a `RibbonReference` (expected note, e.g. the
// session/mock-script note) deviation is sung vs that note's center
// (midi·100 + cents_ref, C-2.3). With nil reference (standalone tuner) the
// nearest equal-tempered semitone is the reference — honest for live input.

import Foundation
import EngineCore

/// Grading tolerance presets (UX §3.4 / Settings → Grading, C-5 default ±50).
public enum RibbonTolerance: Double, CaseIterable, Sendable, Identifiable {
    case wide = 50
    case medium = 25
    case narrow = 10

    public var id: Double { rawValue }
    /// Tolerance in cents (|dev| ≤ tol is in-tune, boundary inclusive).
    public var cents: Double { rawValue }
    /// Chip label ("±50¢").
    public var label: String { "±\(Int(rawValue))¢" }
}

/// Correction-direction arrow semantics (UX §3.4 — colors never carry meaning
/// alone; flat → sing higher ↑, sharp → sing lower ↓).
public enum RibbonDirection: Sendable, Equatable {
    case up      // sing higher (cursor flat)
    case down    // sing lower (cursor sharp)
    case none
}

/// Octave-equivalence badge (UX §3.5): silent folding would lie, so a folded
/// in-tune octave ALWAYS shows the badge. `.up` renders "8va", `.down` "8vb".
public enum OctaveBadge: Sendable, Equatable {
    case up
    case down
}

/// Cursor/trace state (UX §3.4 table). Low confidence is NOT a state — it is a
/// rendering flag on any voiced state (70% opacity + dashed trace, §3.7).
public enum RibbonState: Sendable, Equatable {
    case inTune
    case flat
    case sharp
    case unvoiced
}

/// The expected note a live frame is compared against (UX §3.4 "reference =
/// midi*100 + cents_ref"). From a NoteTrack note (C-2.3) or session context.
public struct RibbonReference: Sendable, Equatable {
    /// Equal-tempered center of the expected note (C4 = 60).
    public let midi: Int
    /// Reference's own deviation from equal temperament (C-2.3, ±50).
    public let centsRef: Double

    public init(midi: Int, centsRef: Double = 0) {
        self.midi = midi
        self.centsRef = centsRef
    }

    /// Absolute cents position of the reference center.
    public var absoluteCents: Double { Double(midi) * 100 + centsRef }

    /// Reference center frequency in Hz.
    public var hz: Double {
        PitchMath.hz(forMidi: midi) * pow(2.0, centsRef / 1200.0)
    }
}

/// One decided ribbon display value — the view's entire input per frame.
public struct RibbonReading: Equatable, Sendable {
    public let state: RibbonState
    public let direction: RibbonDirection
    public let octaveBadge: OctaveBadge?
    /// Nearest equal-tempered MIDI note of the sung pitch (note-name readout).
    public let nearestMidi: Int?
    /// Signed deviation in cents vs the reference (or vs the nearest
    /// semitone's center when reference is nil). + = sharper.
    public let cents: Double
    public let confidence: Double
    /// 0.5 ≤ confidence < 0.75 (UX §3.4 lowConfidence row) → render 70%
    /// opacity + dashed trace. Always false when unvoiced.
    public let lowConfidence: Bool

    /// VoiceOver summary text (UX §7: ≤ 1 Hz cadence, words not colors).
    public var spokenSummary: String {
        switch state {
        case .unvoiced:
            return "unvoiced"
        case .inTune:
            let badge = octaveBadge == .up ? ", one octave up" : octaveBadge == .down ? ", one octave down" : ""
            return "\(PitchMath.noteName(forMidi: nearestMidi ?? 0)), in tune\(badge)"
        case .flat:
            return "\(PitchMath.noteName(forMidi: nearestMidi ?? 0)), \(Int(abs(cents).rounded())) cents flat, sing higher"
        case .sharp:
            return "\(PitchMath.noteName(forMidi: nearestMidi ?? 0)), \(Int(abs(cents).rounded())) cents sharp, sing lower"
        }
    }
}

public enum RibbonMapper {

    /// Voicing gate (UX §3.4): hz == 0.0 OR confidence < 0.5 ⇒ unvoiced.
    public static let voicedMinimumConfidence: Double = 0.5
    /// Below this (voiced) the render dims/dashes (UX §3.4 lowConfidence row).
    public static let lowConfidenceThreshold: Double = 0.75

    /// Decides one reading. `hz`/`confidence` are C-2.4 frame values.
    ///
    /// - reference: expected note, or nil for standalone-tuner mode (nearest
    ///   semitone is the reference).
    /// - tolerance: in-tune half-width in cents (default 50, C-5).
    /// - octaveEquivalence: ON folds exact octaves to in-tune WITH a badge
    ///   (UX §3.5); OFF renders plain flat/sharp.
    public static func reading(hz: Double,
                               confidence: Double,
                               reference: RibbonReference?,
                               tolerance: Double,
                               octaveEquivalence: Bool) -> RibbonReading {
        // Unvoiced gate first (spec order): hz == 0.0 or confidence < 0.5.
        guard hz > 0, confidence >= voicedMinimumConfidence else {
            return RibbonReading(state: .unvoiced, direction: .none, octaveBadge: nil,
                                 nearestMidi: nil, cents: 0, confidence: confidence,
                                 lowConfidence: false)
        }

        let nearest = PitchMath.midiNearest(forHz: hz) ?? 60
        let dev: Double
        if let ref = reference {
            dev = PitchMath.cents(from: ref.hz, to: hz)
        } else {
            dev = PitchMath.centsRef(hz: hz, midi: nearest)
        }

        let low = confidence < lowConfidenceThreshold

        // Octave-equivalence (UX §3.5): fold-match in-tune while outside the
        // semitone itself → in-tune color + mandatory badge (honesty rule).
        if octaveEquivalence, abs(dev) > tolerance {
            let folded = PitchMath.foldedCents(dev)
            if abs(folded) <= tolerance {
                return RibbonReading(state: .inTune, direction: .none,
                                     octaveBadge: dev > 0 ? .up : .down,
                                     nearestMidi: nearest, cents: dev,
                                     confidence: confidence, lowConfidence: low)
            }
        }

        let state: RibbonState
        let direction: RibbonDirection
        if abs(dev) <= tolerance {
            state = .inTune
            direction = .none
        } else if dev < 0 {
            state = .flat
            direction = .up
        } else {
            state = .sharp
            direction = .down
        }
        return RibbonReading(state: state, direction: direction, octaveBadge: nil,
                             nearestMidi: nearest, cents: dev,
                             confidence: confidence, lowConfidence: low)
    }

    /// Convenience over a contract frame (C-2.4 PitchFrame).
    public static func reading(frame: PitchFrame,
                               reference: RibbonReference?,
                               tolerance: Double,
                               octaveEquivalence: Bool) -> RibbonReading {
        reading(hz: frame.hz, confidence: frame.confidence, reference: reference,
                tolerance: tolerance, octaveEquivalence: octaveEquivalence)
    }
}
