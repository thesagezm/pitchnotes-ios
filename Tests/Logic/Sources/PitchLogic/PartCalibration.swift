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
// WHERE IT IS STORED (RULED — C-15, D-47 §2): the range override is NOT a note
// operation, so C-11 has no home for it. It lives in `corrections/song.json`,
// next to the per-part overlay files. The STORED shape lives here
// (`StoredPartRangeOverride`) so the code and the contract cannot drift apart:
//
//   "T1":   { "preset": "G3–E5" }
//   "BASS": { "custom": { "minMidi": 40, "maxMidi": 60 } }
//
// THE ±2 SEMITONE NUDGE IS NOT IN THAT FILE (C-15 rule 2, D-47 §4). C-6.1
// fixes the nudge as DEVICE-LOCAL ("never in the bundle") — it is the
// singer/mic calibration and belongs to the device, so opening the same song
// on another device must not carry this device's offset along. The writer
// therefore NEVER writes `nudgeSemitones`, and a reader that meets the key
// IGNORES it (never a validation error, never a reason to quarantine the
// file). The nudge lives in `DeviceCalibration` (the device-local store) and
// is applied ON TOP of the effective range, exactly as C-6.1 describes.
//
// THE PRESET LABEL IS DISPLAY-ONLY (C-15 rule 2, D-47 §3): the bounds always
// come from C-6.1's row for that PART, looked up by the C-1 rawValue key. A
// stale or unknown label is NOT an error and never rejects the file.
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
    /// The C-6.1 preset's range LABEL (e.g. "G3–E5") when the preset mode is
    /// used.
    ///
    /// DISPLAY-ONLY (C-15 rule 2, D-47 §3): the authoritative bounds come
    /// from C-6.1's row for this part, looked up by the C-1 rawValue key —
    /// never from this string. A stale or unknown label is not an error.
    public var presetName: String?

    /// V9's MIDI range, verbatim (the note validator's bounds).
    public static let midiRange: ClosedRange<Int> = 24...96

    /// Builds an override, SANITIZING the inputs (never a trap, never an
    /// out-of-contract value):
    ///   · the bounds are clamped into V9's 24…96 and kept ordered.
    ///
    /// THE OVERRIDE CARRIES THE RANGE ONLY (C-15 rule 2): the ±2 semitone
    /// nudge is device-local and lives in `DeviceCalibration`, not here.
    public init(part: Part, mode: Mode, midiLow: Int, midiHigh: Int,
                presetName: String? = nil) {
        self.part = part
        self.mode = mode
        let low = min(max(midiLow, PartRangeOverride.midiRange.lowerBound),
                      PartRangeOverride.midiRange.upperBound - 1)
        let high = min(max(midiHigh, low + 1), PartRangeOverride.midiRange.upperBound)
        self.midiLow = low
        self.midiHigh = high
        self.presetName = mode == .custom ? nil : presetName
    }

    /// The C-6.1 preset for a part. The bounds are filled from the contract
    /// table so the stored JSON says WHICH preset the override was made from
    /// (the table itself stays the truth about the bounds).
    ///
    /// No nudge parameter: the nudge is device-local (C-15 rule 2) and is
    /// applied by `PartCalibration.effectiveRange`, not stored here.
    public static func preset(for part: Part) -> PartRangeOverride {
        let contractPreset = EngineCore.PartRangePresets.preset(for: part)
        return PartRangeOverride(part: part,
                                 mode: .preset,
                                 midiLow: contractPreset?.midiLow ?? PartRangeOverride.midiRange.lowerBound,
                                 midiHigh: contractPreset?.midiHigh ?? PartRangeOverride.midiRange.upperBound,
                                 presetName: contractPreset?.presetName)
    }

    /// A custom range for one song.
    public static func custom(for part: Part, midiLow: Int, midiHigh: Int) -> PartRangeOverride {
        PartRangeOverride(part: part, mode: .custom,
                          midiLow: midiLow, midiHigh: midiHigh)
    }
}

// MARK: - The stored (JSON) form — C-15's shape

/// The stored form of ONE range override (C-15's exact JSON).
///
/// It lives at file scope (not inside `SongCalibrationOverlay`) so the
/// calibration file's hand-written decoder and this type cannot drift.
///
/// THE NUDGE (C-15 rule 2, D-47 §4): the writer NEVER writes
/// `nudgeSemitones` into this file, and the reader IGNORES it if it meets
/// one — an older build's file (or a hand-edited one) still loads, and the
/// key is never a validation error and never a reason to quarantine the
/// file. The device-local nudge lives in `DeviceCalibration`.
struct StoredPartRangeOverride: Codable {

    var preset: String?
    var custom: CustomBounds?

    /// The custom MIDI bounds.
    struct CustomBounds: Codable {
        var minMidi: Int
        var maxMidi: Int
    }

    private enum CodingKeys: String, CodingKey {
        case preset, custom
        /// The IGNORED legacy key (C-15 rule 2). It is never encoded and
        /// never used — it is read only so the decoder stays tolerant.
        case ignoredNudgeSemitones = "nudgeSemitones"
    }

    /// The override this stored form describes (for the given part).
    ///
    /// The bounds come from C-6.1's row for this part (looked up by the C-1
    /// rawValue key), NEVER from the stored label — the label is display-only
    /// (C-15 rule 2, D-47 §3).
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
                                 presetName: preset ?? contractPreset?.presetName)
    }

    init(preset: String? = nil, custom: CustomBounds? = nil) {
        self.preset = preset
        self.custom = custom
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let custom {
            try container.encode(custom, forKey: .custom)
        } else {
            try container.encode(preset ?? "", forKey: .preset)
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
        self.custom = custom
        // The legacy `nudgeSemitones` key is READ and IGNORED (C-15 rule 2):
        // its presence is never an error and never quarantines the file.
        _ = try container.decodeIfPresent(Int.self, forKey: .ignoredNudgeSemitones)
    }
}

extension PartRangeOverride {
    /// The stored form of this override (C-15's exact JSON — the RANGE only).
    func storedForm() -> StoredPartRangeOverride {
        switch mode {
        case .custom:
            return StoredPartRangeOverride(custom: StoredPartRangeOverride.CustomBounds(
                minMidi: midiLow, maxMidi: midiHigh))
        case .preset:
            return StoredPartRangeOverride(preset: presetName ?? "")
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

    /// The band for one part, with the song's override and the device's nudge
    /// applied.
    ///
    /// THE TWO LAYERS (C-6.1 + C-15 rule 2):
    ///   · the SONG's range — the per-song override from `corrections/song.json`
    ///     (a preset or a custom range), and
    ///   · the DEVICE's nudge — the singer's/mic's ±2 semitone calibration,
    ///     which is device-local and applied ON TOP of the effective range.
    ///
    /// Returns nil for parts with no C-6.1 preset (VP, LEAD, INSTRUMENTAL,
    /// VOCALS) — they are not graded singing parts.
    ///
    /// A CUSTOM range is the range: the device nudge does not move it (C-6.1
    /// applies the nudge to the PRESET "before use", and a custom range
    /// replaces the preset outright).
    public static func effectiveRange(for part: Part,
                                      rangeOverride: PartRangeOverride?,
                                      deviceNudge: Int = 0) -> EffectivePartRange? {
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

        let nudge = EngineCore.PartRangePresets.clampNudge(deviceNudge)
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

    /// The effective ranges for a set of parts, with the song's overrides and
    /// the device's nudges.
    ///
    /// A nil calibration (no `corrections/song.json`) ⇒ the C-6.1 presets,
    /// exactly as before (the absence rule) — plus the device nudge, which is
    /// a device fact and never part of the song's file.
    public static func effectiveRanges(calibration: SongCalibrationOverlay?,
                                       parts: [Part],
                                       deviceNudges: [Part: Int] = [:]) -> [Part: EffectivePartRange] {
        var result: [Part: EffectivePartRange] = [:]
        for part in parts {
            if let range = effectiveRange(for: part,
                                          rangeOverride: calibration?.rangeOverride(for: part),
                                          deviceNudge: deviceNudges[part] ?? 0) {
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
