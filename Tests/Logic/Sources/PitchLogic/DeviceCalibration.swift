import Foundation
import EngineCore

// DeviceCalibration — the DEVICE-LOCAL calibration (C-6.1, UX §3.6).
//
// WHY IT EXISTS (D-47 §4, C-15 rule 2):
// C-6.1 fixes the per-part semitone nudge (−2…+2, default 0) and the
// mic-profile offset as **device-local, "never in the bundle"**. The per-song
// file `corrections/song.json` therefore carries the RANGE only. If the nudge
// rode in the bundle, opening the same song on another device would apply
// this device's offset to it — precisely what C-6.1 forbids.
//
// WHERE IT LIVES: `UserDefaults`, one key, per app install. It is NOT in the
// SongBundle, NOT in `corrections/`, and never leaves the device.
//
// HONESTY: a nudge is a CALIBRATION, not a grading rule. It shifts the band
// (the follow window and the `fmin`/`fmax` handed to the engine); it never
// gates a note (C-6.1 + D-12) and it never changes a note's MIDI.

/// The device's per-part calibration.
///
/// The nudge is an INTEGER number of semitones, clamped to C-6.1's ±2.
public struct DeviceCalibration: Equatable, Sendable {

    /// The `UserDefaults` key the nudges live under.
    public static let defaultsKey = "deviceCalibration.partNudges"

    /// The per-part nudges, in semitones (always within C-6.1's ±2).
    ///
    /// A part with no entry has NO nudge (0).
    public private(set) var nudges: [Part: Int]

    /// An empty calibration (the default state).
    public init(nudges: [Part: Int] = [:]) {
        self.nudges = [:]
        for (part, value) in nudges {
            setNudge(value, for: part)
        }
    }

    /// The nudge for one part (0 when there is none).
    public func nudge(for part: Part) -> Int {
        nudges[part] ?? 0
    }

    /// Sets one part's nudge, clamped to C-6.1's ±2.
    ///
    /// A nudge of 0 REMOVES the entry (the default state is no entry — the
    /// file stays small and "unset" is distinguishable from "set to zero").
    public mutating func setNudge(_ value: Int, for part: Part) {
        let clamped = EngineCore.PartRangePresets.clampNudge(value)
        if clamped == 0 {
            nudges.removeValue(forKey: part)
        } else {
            nudges[part] = clamped
        }
    }

    /// Clears one part's nudge.
    public mutating func clearNudge(for part: Part) {
        nudges.removeValue(forKey: part)
    }

    /// Clears every nudge.
    public mutating func reset() {
        nudges.removeAll()
    }

    // MARK: - Persistence (the device's own store)

    /// Reads the calibration from the device's defaults.
    ///
    /// A missing key ⇒ an empty calibration (the absence rule: an unset
    /// device behaves exactly as the contract's table says). A value that is
    /// not a usable dictionary ⇒ an empty calibration, never a crash.
    public static func load(from defaults: UserDefaults = .standard) -> DeviceCalibration {
        guard let stored = defaults.dictionary(forKey: defaultsKey) else {
            return DeviceCalibration()
        }
        var nudges: [Part: Int] = [:]
        for (raw, value) in stored {
            guard let part = Part(rawValue: raw) else { continue }
            guard let number = value as? Int else { continue }
            nudges[part] = EngineCore.PartRangePresets.clampNudge(number)
        }
        return DeviceCalibration(nudges: nudges)
    }

    /// Writes the calibration to the device's defaults.
    public func save(to defaults: UserDefaults = .standard) {
        var stored: [String: Int] = [:]
        for (part, value) in nudges {
            stored[part.rawValue] = value
        }
        defaults.set(stored, forKey: DeviceCalibration.defaultsKey)
    }
}
