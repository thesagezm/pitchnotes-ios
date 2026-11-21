import Foundation

// C-6.1 · Part range presets (CONTRACTS.md v0.1, RATIFIED 2026-11-21 — L-102;
// implementation = P-105, PAUL lane). From UX.md §3.6 (X-001), ratified
// VERBATIM. Single source of truth for both lanes: part selection UI,
// fmin/fmax band filtering (pitchFrames/gradingFrames), and ribbon
// follow-window centering. Equal-tempered MIDI (A440, C4 = 60); Hz rounded
// to 0.1 in the fixed table (computed via EngineContract.hzForMidi).
//
// Keys are C-1 rawValues (uppercase). SOPRANO/ALTO appear only for female
// chorale bundles; male ensembles use the five default presets.
//
// Calibration (user-local, never in the bundle — Jess lane, UX §3.6): per-part
// integer semitone nudge −2…+2 (default 0) and a mic-profile offset (cents),
// applied to the preset before use: fmin/fmax = preset shifted by the nudge.
// The preset TABLE below is fixed contract data — calibration produces a
// derived band; it never mutates the table. Per-song custom ranges arrive
// with the M3 calibration task (J-302) and extend this table additively.
//
// Range presets constrain FILTERING only; they are not hard gates (a singer
// outside their preset range still produces frames — the UI shows the honest
// deviation; D-12 honesty rule).

/// One fixed C-6.1 preset row.
public struct PartRangePreset: Sendable, Equatable {
    public let part: Part
    /// Preset name from UX §3.6, e.g. "E2–G3" (display only).
    public let presetName: String
    /// Inclusive MIDI bounds (contract table).
    public let midiLow: Int
    public let midiHigh: Int
    /// Hz bounds, rounded to 0.1 per C-6.1 (derived from midiLow/midiHigh).
    public let fmin: Double
    public let fmax: Double

    public init(part: Part, presetName: String, midiLow: Int, midiHigh: Int) {
        self.part = part
        self.presetName = presetName
        self.midiLow = midiLow
        self.midiHigh = midiHigh
        // C-6.1: Hz rounded to 0.1.
        self.fmin = (EngineContract.hzForMidi(Double(midiLow)) * 10.0).rounded() / 10.0
        self.fmax = (EngineContract.hzForMidi(Double(midiHigh)) * 10.0).rounded() / 10.0
    }
}

/// The C-6.1 table (verbatim) + calibration application.
public enum PartRangePresets {

    /// Calibration nudge bounds (C-6.1): per-part integer semitone nudge −2…+2.
    public static let nudgeLimit = 2

    /// The fixed C-6.1 table, verbatim:
    /// BASS 40–55, BARITONE 45–62, BARITENOR 48–65, T2 52–69, T1 55–76,
    /// SOPRANO 60–79, ALTO 55–74 (MIDI).
    public static let all: [Part: PartRangePreset] = [
        .bass:      PartRangePreset(part: .bass,      presetName: "E2–G3", midiLow: 40, midiHigh: 55),
        .baritone:  PartRangePreset(part: .baritone,  presetName: "A2–D4", midiLow: 45, midiHigh: 62),
        .baritenor: PartRangePreset(part: .baritenor, presetName: "C3–F4", midiLow: 48, midiHigh: 65),
        .t2:        PartRangePreset(part: .t2,        presetName: "E3–A4", midiLow: 52, midiHigh: 69),
        .t1:        PartRangePreset(part: .t1,        presetName: "G3–E5", midiLow: 55, midiHigh: 76),
        .soprano:   PartRangePreset(part: .soprano,   presetName: "C4–G5", midiLow: 60, midiHigh: 79),
        .alto:      PartRangePreset(part: .alto,      presetName: "G3–D5", midiLow: 55, midiHigh: 74),
    ]

    /// Preset for a part; nil for non-singable parts (VP, LEAD, INSTRUMENTAL).
    public static func preset(for part: Part) -> PartRangePreset? {
        all[part]
    }

    /// Clamps a user nudge into the contract range −2…+2.
    public static func clampNudge(_ nudge: Int) -> Int {
        min(nudgeLimit, max(-nudgeLimit, nudge))
    }

    /// Calibrated band for a part: the C-6.1 preset shifted by the per-part
    /// semitone nudge (clamped −2…+2), then by the mic-profile offset in cents
    /// (+ = band shifts sharp/up). Full float precision (the 0.1 rounding is a
    /// fixed-table display convention). Returns nil for parts without a preset.
    ///
    /// Band application is FILTERING only (C-6.1): callers must not gate frames
    /// on it — outside-band frames stay honest per D-12.
    public static func calibratedBand(for part: Part,
                                      nudgeSemitones: Int,
                                      micOffsetCents: Double = 0) -> (fmin: Double, fmax: Double)? {
        guard let preset = all[part] else { return nil }
        let nudge = clampNudge(nudgeSemitones)
        let lo = EngineContract.detune(hz: EngineContract.hzForMidi(Double(preset.midiLow + nudge)),
                                       cents: micOffsetCents)
        let hi = EngineContract.detune(hz: EngineContract.hzForMidi(Double(preset.midiHigh + nudge)),
                                       cents: micOffsetCents)
        return (fmin: lo, fmax: hi)
    }
}
