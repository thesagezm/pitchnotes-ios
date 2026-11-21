// PartRangePresets — CONTRACTS v0.1 C-6.1 part vocal-range presets, verbatim.
//
// Single source of truth for part-selection UI chips (J-101), fmin/fmax band
// filtering, and ribbon follow-window centering (UX §3.6). Values are
// equal-tempered MIDI (A440, C4 = 60); Hz derives from PitchMath (rounded to
// 0.1 in the contract table — derived values match within 0.05, tested).
//
// INTERIM HOME (X-006 era): Paul's P-105 implements this table in EngineCore;
// when that lands, this file's `all` table swaps to his (J-101 consumes via
// PitchLogic, so the swap is one file — zero UI changes). Values here are
// asserted verbatim by tests so drift is caught either way.
//
// Calibration (C-6.1): per-part integer semitone nudge −2…+2 (default 0) and a
// mic-profile offset are USER-LOCAL settings (Jess lane, UX §3.6) applied to a
// preset before use; presets themselves are fixed contract data. Persistence
// arrives with J-405 (M4); M1 uses default nudges.

import Foundation
import EngineCore

/// One C-6.1 preset row: part + preset span in MIDI and derived Hz.
public struct PartRange: Equatable, Sendable {
    public let part: Part
    /// Contract preset label, e.g. "E2–G3" (en dash, verbatim C-6.1).
    public let presetName: String
    public let midiLow: Int
    public let midiHigh: Int

    public init(part: Part, presetName: String, midiLow: Int, midiHigh: Int) {
        self.part = part
        self.presetName = presetName
        self.midiLow = midiLow
        self.midiHigh = midiHigh
    }

    /// Contract Hz low (rounded to 0.1 — C-6.1 "Hz rounded to 0.1").
    public var hzLow: Double { (PitchMath.hz(forMidi: midiLow) * 10).rounded() / 10 }
    /// Contract Hz high (rounded to 0.1).
    public var hzHigh: Double { (PitchMath.hz(forMidi: midiHigh) * 10).rounded() / 10 }

    /// Chip label: "Bass E2–G3" (UX §3.6).
    public var displayName: String { "\(part.displayName) \(presetName)" }

    /// Center of the range in absolute cents — initial follow-window center
    /// when no reference note is active (UX §3.3).
    public var centerCents: Double {
        (Double(midiLow) + Double(midiHigh)) / 2 * 100
    }
}

public enum PartRangePresets {

    // MARK: C-6.1 table (verbatim MIDI spans)

    public static let bass =       PartRange(part: .bass,       presetName: "E2–G3", midiLow: 40, midiHigh: 55)
    public static let baritone =   PartRange(part: .baritone,   presetName: "A2–D4", midiLow: 45, midiHigh: 62)
    public static let baritenor =  PartRange(part: .baritenor,  presetName: "C3–F4", midiLow: 48, midiHigh: 65)
    public static let t2 =         PartRange(part: .t2,         presetName: "E3–A4", midiLow: 52, midiHigh: 69)
    public static let t1 =         PartRange(part: .t1,         presetName: "G3–E5", midiLow: 55, midiHigh: 76)
    public static let soprano =    PartRange(part: .soprano,    presetName: "C4–G5", midiLow: 60, midiHigh: 79)
    public static let alto =       PartRange(part: .alto,       presetName: "G3–D5", midiLow: 55, midiHigh: 74)

    /// All ratified presets, C-1 display order (soprano … bass per sortOrder —
    /// UI sorts chips per C-1; SOPRANO/ALTO only surface for female chorales).
    public static let all: [PartRange] = [soprano, alto, t1, t2, baritenor, baritone, bass]

    /// Preset for a part, or nil for structural markers (VP/LEAD/INSTRUMENTAL
    /// have no C-6.1 row — they are not graded singing parts).
    public static func range(for part: Part) -> PartRange? {
        all.first { $0.part == part }
    }
}
