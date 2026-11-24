import Foundation
import EngineCore

// PartCalibration (J-302) — the PER-SONG range override.
//
// C-6.1 (CONTRACTS v0.1, EngineCore's table is the single source of truth):
// each part has a fixed preset range, and the user may nudge it by −2…+2
// semitones. Paul's comment on the contract table says it plainly:
//
//   "Per-song custom ranges arrive with the M3 calibration task (J-302) and
//    extend this table additively."
//
// So J-302 adds the third mode — a CUSTOM range — and keeps the other two
// exactly as the contract has them:
//
//   · preset          — the C-6.1 table, untouched (the default);
//   · preset + nudge  — the C-6.1 table shifted by −2…+2 semitones;
//   · custom          — the user's own MIDI bounds for this song.
//
// THE TABLE IS NEVER MUTATED: an override derives a band (EngineCore's
// `PartRangePresets.calibratedBand` for the preset modes), it does not
// change the contract.
//
// HONESTY (C-6.1 + D-12): a range is a FILTERING band, never a hard gate. A
// note outside the range is MARKED, not hidden and not rejected — the singer
// may genuinely sing outside the preset.

// MARK: - The override

/// One part's per-song range override.
public struct PartRangeOverride: Codable, Equatable, Sendable {

    /// Which mode the override uses.
    public enum Mode: String, Codable, Equatable, Sendable {
        /// The C-6.1 contract preset (optionally nudged).
        case preset
        /// The user's own MIDI bounds for this song.
        case custom
    }

    public var mode: Mode
    /// The custom lower bound (MIDI). Meaningful in `.custom` mode; in
    /// `.preset` mode it holds the preset's bound for reference.
    public var midiLow: Int
    /// The custom upper bound (MIDI).
    public var midiHigh: Int
    /// The C-6.1 semitone nudge, −2…+2. Only in `.preset` mode.
    public var nudgeSemitones: Int

    /// V9's MIDI range, verbatim (the note validator's bounds).
    public static let midiRange: ClosedRange<Int> = 24...96

    /// Builds an override, SANITIZING the inputs (never a trap, never an
    /// out-of-contract value):
    ///   · the bounds are clamped into V9's 24…96 and kept ordered;
    ///   · the nudge is clamped to C-6.1's ±2;
    ///   · a custom range ignores the nudge (the bounds ARE the range).
    public init(mode: Mode, midiLow: Int, midiHigh: Int, nudgeSemitones: Int = 0) {
        self.mode = mode
        let low = min(max(midiLow, PartRangeOverride.midiRange.lowerBound),
                      PartRangeOverride.midiRange.upperBound - 1)
        let high = min(max(midiHigh, low + 1), PartRangeOverride.midiRange.upperBound)
        self.midiLow = low
        self.midiHigh = high
        self.nudgeSemitones = mode == .custom
            ? 0
            : EngineCore.PartRangePresets.clampNudge(nudgeSemitones)
    }

    /// The C-6.1 preset for a part, with an optional nudge. The bounds are
    /// filled from the contract table so the stored JSON says WHICH preset
    /// the override was made from (the table itself stays the truth).
    public static func preset(for part: Part, nudgeSemitones: Int = 0) -> PartRangeOverride {
        let nudge = EngineCore.PartRangePresets.clampNudge(nudgeSemitones)
        let preset = EngineCore.PartRangePresets.preset(for: part)
        return PartRangeOverride(mode: .preset,
                                 midiLow: preset?.midiLow ?? PartRangeOverride.midiRange.lowerBound,
                                 midiHigh: preset?.midiHigh ?? PartRangeOverride.midiRange.upperBound,
                                 nudgeSemitones: nudge)
    }

    /// A custom range for one song.
    public static func custom(midiLow: Int, midiHigh: Int) -> PartRangeOverride {
        PartRangeOverride(mode: .custom, midiLow: midiLow, midiHigh: midiHigh, nudgeSemitones: 0)
    }
}

// MARK: - The effective range

/// The band a part actually uses for this song.
public struct EffectivePartRange: Equatable, Sendable {
    public let part: Part
    public let midiLow: Int
    public let midiHigh: Int
    /// Hz bounds (full precision — the 0.1 rounding in the contract table is
    /// a display convention, like `PartRangePresets.calibratedBand`).
    public let fmin: Double
    public let fmax: Double
    /// True when the user set a custom range (the preset modes are false).
    public let isCustom: Bool
    /// The C-6.1 preset's name (e.g. "E2–G3") when the preset mode is used.
    public let presetName: String?
    /// The C-6.1 nudge applied (0 in custom mode).
    public let nudgeSemitones: Int

    public init(part: Part, midiLow: Int, midiHigh: Int, fmin: Double, fmax: Double,
                isCustom: Bool, presetName: String?, nudgeSemitones: Int) {
        self.part = part
        self.midiLow = midiLow
        self.midiHigh = midiHigh
        self.fmin = fmin
        self.fmax = fmax
        self.isCustom = isCustom
        self.presetName = presetName
        self.nudgeSemitones = nudgeSemitones
    }

    /// The chip label: "Bass E2–G3", "T1 G3–E5 (+1 st)", "Bass 40–55 (custom)".
    public var label: String {
        if isCustom {
            return "\(part.displayName) \(midiLow)–\(midiHigh) (custom)"
        }
        let base = "\(part.displayName) \(presetName ?? "\(midiLow)–\(midiHigh)")"
        return nudgeSemitones == 0
            ? base
            : "\(base) (\(nudgeSemitones > 0 ? "+" : "−")\(abs(nudgeSemitones)) st)"
    }

    /// Is this MIDI note inside the band?
    public func contains(midi: Int) -> Bool {
        midi >= midiLow && midi <= midiHigh
    }
}

// MARK: - The resolver

/// Resolves the effective per-song ranges.
public enum PartCalibration {

    /// The band for one part, with the song's override applied.
    ///
    /// Returns nil for parts with no C-6.1 preset (VP, LEAD, INSTRUMENTAL,
    /// VOCALS) — they are not graded singing parts.
    public static func effectiveRange(for part: Part,
                                      override: PartRangeOverride?) -> EffectivePartRange? {
        guard let preset = EngineCore.PartRangePresets.preset(for: part) else { return nil }

        if let override, override.mode == .custom {
            let fmin = EngineContract.hzForMidi(Double(override.midiLow))
            let fmax = EngineContract.hzForMidi(Double(override.midiHigh))
            return EffectivePartRange(part: part,
                                      midiLow: override.midiLow,
                                      midiHigh: override.midiHigh,
                                      fmin: fmin,
                                      fmax: fmax,
                                      isCustom: true,
                                      presetName: nil,
                                      nudgeSemitones: 0)
        }

        let nudge = override.map { EngineCore.PartRangePresets.clampNudge($0.nudgeSemitones) } ?? 0
        guard let band = EngineCore.PartRangePresets.calibratedBand(for: part,
                                                                    nudgeSemitones: nudge) else {
            return nil
        }
        return EffectivePartRange(part: part,
                                  midiLow: preset.midiLow + nudge,
                                  midiHigh: preset.midiHigh + nudge,
                                  fmin: band.fmin,
                                  fmax: band.fmax,
                                  isCustom: false,
                                  presetName: preset.presetName,
                                  nudgeSemitones: nudge)
    }

    /// The effective ranges for a set of parts, with an overlay's overrides.
    public static func effectiveRanges(overlay: CorrectionOverlay,
                                       parts: [Part]) -> [Part: EffectivePartRange] {
        var result: [Part: EffectivePartRange] = [:]
        for part in parts {
            if let range = effectiveRange(for: part, override: overlay.rangeOverride(for: part)) {
                result[part] = range
            }
        }
        return result
    }

    /// How many notes of each part fall OUTSIDE its effective range.
    ///
    /// A count, never a rejection: the notes stay on the roll and the UI
    /// marks them (D-12 honesty — a range is a filter, not a gate).
    public static func notesOutsideRange(in tracks: [Part: NoteTrack],
                                         ranges: [Part: EffectivePartRange]) -> [Part: Int] {
        var counts: [Part: Int] = [:]
        for (part, track) in tracks {
            guard let range = ranges[part] else { continue }
            let outside = track.notes.filter { !range.contains(midi: $0.midi) }.count
            if outside > 0 { counts[part] = outside }
        }
        return counts
    }
}
