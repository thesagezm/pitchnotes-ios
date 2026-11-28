import Foundation

// J-405 · the device-local GRADING SETTINGS store (the user-facing half of
// C-19's `GradingConfig` — UX §6.4). The settings screen edits THIS; the
// session reads it as its config's BASE (the launcher's per-session picks
// still win for tolerance/octave/count-in).
//
// THE HONESTY RAILS (C-19, verbatim posture):
//   · every value is stored RAW and BOUNDED at the UI (sliders/pickers never
//     leave the contract ranges);
//   · the GRADING path converts through `GradingConfig.clampedForGrading()` —
//     a value that reached the store out-of-bounds (a hand-edited plist, a
//     future schema drift) is CLAMPED and REPORTED, never silently used;
//   · a weights set that does not sum to 1.0 ± 0.001 is REJECTED AT SAVE —
//     every persisted config is gradable (C-19: never normalized);
//   · absence/corruption of the stored payload ⇒ the contract defaults
//     (the LatencyCalibration honesty: user data never crashes the app);
//   · this is DEVICE-LOCAL user data — it never enters a SongBundle (C-19).
//
// PERSISTENCE: one `UserDefaults` key holding the JSON payload (the
// LatencyCalibration/DeviceCalibration pattern). `haptics` is a UX
// preference (§6.4) and deliberately NOT part of GradingConfig — it never
// touches scoring.

public struct GradingSettings: Codable, Equatable, Sendable {

    /// int [10, 50], default 50 (C-19; ±25/±10 are the canonical presets).
    public var toleranceCents: Int
    /// bool, default true (C-19's octave equivalence CLASSES).
    public var octaveEquivalence: Bool
    /// int [80, 120], default 100 (C-5's band).
    public var onsetGrace_ms: Int
    /// int [10, 100], default 50 (mean-centered vibrato swing).
    public var vibratoExtentCents: Int
    /// float [-90, -30], default -60 (C-5's loudness gate).
    public var breathGate_db: Double
    /// the C-19 weights (pitch/timing/sustain, sum 1.0 ± 0.001).
    public var weights: GradingWeights
    /// float [1.0, 1.5], default 1.1 (C-4 golden notes).
    public var goldenNoteBonus: Double
    /// one of the four C-19 strings, default "ribbon+notes".
    public var guideLevel: GradingConfig.GuideLevel
    /// int [0, 8], default 4 (the launcher's default count-in).
    public var countIn_beats: Int
    /// bool, default false (C-19).
    public var metronome: Bool
    /// bool, default true — a UX preference (§6.4); NEVER a grading input.
    public var haptics: Bool

    public static let `default` = GradingSettings()

    public init(toleranceCents: Int = 50,
                octaveEquivalence: Bool = true,
                onsetGrace_ms: Int = 100,
                vibratoExtentCents: Int = 50,
                breathGate_db: Double = -60.0,
                weights: GradingWeights = GradingWeights(),
                goldenNoteBonus: Double = 1.1,
                guideLevel: GradingConfig.GuideLevel = .ribbonPlusNotes,
                countIn_beats: Int = 4,
                metronome: Bool = false,
                haptics: Bool = true) {
        self.toleranceCents = toleranceCents
        self.octaveEquivalence = octaveEquivalence
        self.onsetGrace_ms = onsetGrace_ms
        self.vibratoExtentCents = vibratoExtentCents
        self.breathGate_db = breathGate_db
        self.weights = weights
        self.goldenNoteBonus = goldenNoteBonus
        self.guideLevel = guideLevel
        self.countIn_beats = countIn_beats
        self.metronome = metronome
        self.haptics = haptics
    }

    /// The C-19 config the scoring consumes (haptics dropped here).
    public var asGradingConfig: GradingConfig {
        GradingConfig(toleranceCents: toleranceCents,
                      octaveEquivalence: octaveEquivalence,
                      onsetGrace_ms: onsetGrace_ms,
                      vibratoExtentCents: vibratoExtentCents,
                      breathGate_db: breathGate_db,
                      weights: weights,
                      goldenNoteBonus: goldenNoteBonus,
                      guideLevel: guideLevel,
                      countIn_beats: countIn_beats,
                      metronome: metronome)
    }

    // MARK: Codable (the C-19 absence posture: EVERY key is optional in the
    // payload — ABSENT ⇒ the default applies. The synthesized decoder would
    // demand every key; this one never rejects a partial payload.)

    private enum CodingKeys: String, CodingKey {
        case toleranceCents, octaveEquivalence, onsetGrace_ms, vibratoExtentCents
        case breathGate_db, weights, goldenNoteBonus, guideLevel, countIn_beats
        case metronome, haptics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            toleranceCents: try container.decodeIfPresent(Int.self, forKey: .toleranceCents) ?? 50,
            octaveEquivalence: try container.decodeIfPresent(Bool.self, forKey: .octaveEquivalence) ?? true,
            onsetGrace_ms: try container.decodeIfPresent(Int.self, forKey: .onsetGrace_ms) ?? 100,
            vibratoExtentCents: try container.decodeIfPresent(Int.self, forKey: .vibratoExtentCents) ?? 50,
            breathGate_db: try container.decodeIfPresent(Double.self, forKey: .breathGate_db) ?? -60.0,
            weights: try container.decodeIfPresent(GradingWeights.self, forKey: .weights) ?? GradingWeights(),
            goldenNoteBonus: try container.decodeIfPresent(Double.self, forKey: .goldenNoteBonus) ?? 1.1,
            guideLevel: try container.decodeIfPresent(GradingConfig.GuideLevel.self, forKey: .guideLevel) ?? .ribbonPlusNotes,
            countIn_beats: try container.decodeIfPresent(Int.self, forKey: .countIn_beats) ?? 4,
            metronome: try container.decodeIfPresent(Bool.self, forKey: .metronome) ?? false,
            haptics: try container.decodeIfPresent(Bool.self, forKey: .haptics) ?? true)
    }
}

public enum GradingSettingsStore {

    /// The UserDefaults key (one payload; the version IS the key's name —
    /// a future schema change gets a new key and a migration, never a silent
    /// re-read of old data).
    public static let defaultsKey = "grading.settings.v1"

    public enum SettingsError: Error, Equatable {
        /// C-19: REJECTED at the door — never normalized, never persisted.
        case weightsDoNotSum(sum: Double)
    }

    /// Reads the stored settings. ABSENT or CORRUPT ⇒ `.default` (never a
    /// crash, never a half-decoded struct).
    public static func load(from defaults: UserDefaults = .standard) -> GradingSettings {
        guard let payload = defaults.string(forKey: defaultsKey),
              let data = payload.data(using: .utf8) else { return .default }
        do {
            return try JSONDecoder().decode(GradingSettings.self, from: data)
        } catch {
            return .default
        }
    }

    /// Persists the settings. Throws `weightsDoNotSum` — the ONE dishonest
    /// config is refused here (the UI also live-previews the sum; this is
    /// the belt behind the braces).
    public static func save(_ settings: GradingSettings,
                            from defaults: UserDefaults = .standard) throws {
        let sum = settings.weights.sum
        guard abs(sum - 1.0) <= GradingConfig.weightSumTolerance else {
            throw SettingsError.weightsDoNotSum(sum: sum)
        }
        let payload = try JSONEncoder().encode(settings)
        defaults.set(String(data: payload, encoding: .utf8), forKey: defaultsKey)
    }

    /// Clears the key — the settings screen's "Reset to defaults" (the NEXT
    /// load reads `.default`; the defaults live in the type, not the store).
    public static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
