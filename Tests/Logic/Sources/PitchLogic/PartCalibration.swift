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
// WHERE IT IS STORED: the range override is NOT a note operation, so C-11 has
// no home for it. X-216 proposes `corrections/song.json` next to the
// per-part overlay files, with the exact JSON below — LETO HAS THE FINAL SAY.
// The STORED shape lives here (`StoredPartRangeOverride`) so the code and the
// proposal cannot drift apart:
//
//   "T1":   { "preset": "TENOR_1", "nudgeSemitones": 2 }
//   "BASS": { "custom": { "minMidi": 40, "maxMidi": 60 } }
//
// HONESTY (C-6.1 + D-12): a range is a FILTERING band, never a hard gate. A
// note outside the range is MARKED, not hidden and not rejected — the singer
// may genuinely sing outside the preset.

// MARK: - The override

/// One part's per-song range override.
///
/// The override carries its PART so it can name the C-6.1 preset it was made
/// from (the stored JSON says WHICH preset, while the contract table stays
/// the truth about the bounds).
public struct PartRangeOverride: Equatable, Sendable {

    /// Which mode the override uses.
    public enum Mode: String, Equatable, Sendable {
        /// The C-6.1 contract preset (optionally nudged).
        case preset
        /// The user's own MIDI bounds for this song.
        case custom
    }

    /// The part this override is for.
    public var part: Part
    public var mode: Mode
    /// The custom lower bound (MIDI). Meaningful in `.custom` mode; in
    /// `.preset` mode it holds the preset's bound for reference.
    public var midiLow: Int
    /// The custom upper bound (MIDI).
    public var midiHigh: Int
    /// The C-6.1 semitone nudge, −2…+2. Only in `.preset` mode.
    public var nudgeSemitones: Int
    /// The C-6.1 preset name (e.g. "TENOR_1") when the preset mode is used.
    public var presetName: String?

    /// V9's MIDI range, verbatim (the note validator's bounds).
    public static let midiRange: ClosedRange<Int> = 24...96

    /// Builds an override, SANITIZING the inputs (never a trap, never an
    /// out-of-contract value):
    ///   · the bounds are clamped into V9's 24…96 and kept ordered;
    ///   · the nudge is clamped to C-6.1's ±2;
    ///   · a custom range ignores the nudge (the bounds ARE the range).
    public init(part: Part, mode: Mode, midiLow: Int, midiHigh: Int,
                nudgeSemitones: Int = 0, presetName: String? = nil) {
        self.part = part
        self.mode = mode
        let low = min(max(midiLow, PartRangeOverride.midiRange.lowerBound),
                      PartRangeOverride.midiRange.upperBound - 1)
        let high = min(max(midiHigh, low + 1), PartRangeOverride.midiRange.upperBound)
        self.midiLow = low
        self.midiHigh = high
        self.nudgeSemitones = mode == .custom
            ? 0
            : EngineCore.PartRangePresets.clampNudge(nudgeSemitones)
        self.presetName = mode == .custom ? nil : presetName
    }

    /// The C-6.1 preset for a part, with an optional nudge. The bounds are
    /// filled from the contract table so the stored JSON says WHICH preset
    /// the override was made from (the table itself stays the truth).
    public static func preset(for part: Part, nudgeSemitones: Int = 0) -> PartRangeOverride {
        let nudge = EngineCore.PartRangePresets.clampNudge(nudgeSemitones)
        let contractPreset = EngineCore.PartRangePresets.preset(for: part)
        return PartRangeOverride(part: part,
                                 mode: .preset,
                                 midiLow: contractPreset?.midiLow ?? PartRangeOverride.midiRange.lowerBound,
                                 midiHigh: contractPreset?.midiHigh ?? PartRangeOverride.midiRange.upperBound,
                                 nudgeSemitones: nudge,
                                 presetName: contractPreset?.presetName)
    }

    /// A custom range for one song.
    public static func custom(for part: Part, midiLow: Int, midiHigh: Int) -> PartRangeOverride {
        PartRangeOverride(part: part, mode: .custom,
                          midiLow: midiLow, midiHigh: midiHigh, nudgeSemitones: 0)
    }
}

// MARK: - The stored (JSON) form — X-216's shape

/// The stored form of ONE range override (X-216's exact JSON).
///
/// It lives at file scope (not inside `SongCalibrationOverlay`) so the
/// calibration file's hand-written decoder and this type cannot drift.
struct StoredPartRangeOverride: Codable {

    var preset: String?
    var nudgeSemitones: Int?
    var custom: CustomBounds?

    /// The custom MIDI bounds.
    struct CustomBounds: Codable {
        var minMidi: Int
        var maxMidi: Int
    }

    private enum CodingKeys: String, CodingKey {
        case preset, nudgeSemitones, custom
    }

    /// The override this stored form describes (for the given part).
    func makeOverride(for part: Part) -> PartRangeOverride {
        if let custom {
            return PartRangeOverride.custom(for: part,
                                            midiLow: custom.minMidi,
                                            midiHigh: custom.maxMidi)
        }
        let contractPreset = EngineCore.PartRangePresets.preset(for: part)
        return PartRangeOverride(part: part,
                                 mode: .preset,
                                 midiLow: contractPreset?.midiLow ?? PartRangeOverride.midiRange.lowerBound,
                                 midiHigh: contractPreset?.midiHigh ?? PartRangeOverride.midiRange.upperBound,
                                 nudgeSemitones: nudgeSemitones ?? 0,
                                 presetName: preset ?? contractPreset?.presetName)
    }

    init(preset: String? = nil, nudgeSemitones: Int? = nil, custom: CustomBounds? = nil) {
        self.preset = preset
        self.nudgeSemitones = nudgeSemitones
        self.custom = custom
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let custom {
            try container.encode(custom, forKey: .custom)
        } else {
            try container.encode(preset ?? "", forKey: .preset)
            try container.encode(nudgeSemitones ?? 0, forKey: .nudgeSemitones)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let custom = try container.decodeIfPresent(CustomBounds.self, forKey: .custom)
        let preset = try container.decodeIfPresent(String.self, forKey: .preset)
        guard custom != nil || (preset != nil && !preset!.isEmpty) else {
            throw DecodingError.dataCorruptedError(
                forKey: .preset, in: container,
                debugDescription: "A range override needs a 'preset' or a 'custom'.")
        }
        self.preset = preset
        self.nudgeSemitones = try container.decodeIfPresent(Int.self, forKey: .nudgeSemitones)
        self.custom = custom
    }
}

extension PartRangeOverride {
    /// The stored form of this override (X-216's exact JSON).
    func storedForm() -> StoredPartRangeOverride {
        switch mode {
        case .custom:
            return StoredPartRangeOverride(custom: StoredPartRangeOverride.CustomBounds(
                minMidi: midiLow, maxMidi: midiHigh))
        case .preset:
            return StoredPartRangeOverride(preset: presetName ?? "",
                                           nudgeSemitones: nudgeSemitones)
        }
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
                                      rangeOverride: PartRangeOverride?) -> EffectivePartRange? {
        guard let preset = EngineCore.PartRangePresets.preset(for: part) else { return nil }

        if let rangeOverride, rangeOverride.mode == .custom {
            let fmin = EngineContract.hzForMidi(Double(rangeOverride.midiLow))
            let fmax = EngineContract.hzForMidi(Double(rangeOverride.midiHigh))
            return EffectivePartRange(part: part,
                                      midiLow: rangeOverride.midiLow,
                                      midiHigh: rangeOverride.midiHigh,
                                      fmin: fmin,
                                      fmax: fmax,
                                      isCustom: true,
                                      presetName: nil,
                                      nudgeSemitones: 0)
        }

        let nudge = rangeOverride.map { EngineCore.PartRangePresets.clampNudge($0.nudgeSemitones) } ?? 0
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

    /// The effective ranges for a set of parts, with the song's overrides.
    ///
    /// A nil calibration (no `corrections/song.json`) ⇒ the C-6.1 presets,
    /// exactly as before (the absence rule).
    public static func effectiveRanges(calibration: SongCalibrationOverlay?,
                                       parts: [Part]) -> [Part: EffectivePartRange] {
        var result: [Part: EffectivePartRange] = [:]
        for part in parts {
            if let range = effectiveRange(for: part,
                                          rangeOverride: calibration?.rangeOverride(for: part)) {
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
