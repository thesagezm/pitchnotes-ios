import Foundation

// J-401 · C-19 `GradingConfig` (CONTRACTS v1.2, D-58) — the user-tunable
// grading configuration. J-405 owns its UI; the grader (SessionGrader)
// consumes it; the session result records it BY VALUE so a grade is always
// honest about what graded it.
//
// "THE SETTINGS MUST NOT BE ABLE TO MAKE THE SCORING DISHONEST" (C-19), so:
//   · every tunable is BOUNDED — the ranges below are contractual;
//   · a value outside its bound is CLAMPED FOR GRADING and the clamp is
//     REPORTED (`clampedForGrading()` — never silent);
//   · `weights` MUST sum to 1.0 ± 0.001 — a config that does not is
//     REJECTED (`GradingConfigError.weightsDoNotSum`), never silently
//     normalized (a silently rewritten config is a lie about what graded
//     the session);
//   · a decoded file may carry a SUBSET of the keys — ABSENT ⇒ the default
//     applies (C-19's absence rule);
//   · the config is DEVICE-LOCAL user data: it is never written into a
//     SongBundle and never changes a bundle file (C-19).

// MARK: - The weights

/// The three named scoring components (C-19's `weights` object). Each is in
/// [0, 1] and the three MUST sum to 1.0 ± 0.001 (checked, never normalized).
public struct GradingWeights: Codable, Equatable, Sendable {

    /// The pitch component's share (how much being in tune matters).
    public var pitch: Double
    /// The timing component's share (how much starting the note on time
    /// matters — the onset, scored through C-19's onset grace).
    public var timing: Double
    /// The sustain component's share (how much holding the note in tune
    /// matters — the longest continuous in-tune run).
    public var sustain: Double

    public init(pitch: Double = 0.5, timing: Double = 0.3, sustain: Double = 0.2) {
        self.pitch = pitch
        self.timing = timing
        self.sustain = sustain
    }

    /// The sum the 1.0 ± 0.001 rule checks.
    public var sum: Double { pitch + timing + sustain }
}

// MARK: - The config

public struct GradingConfig: Codable, Equatable, Sendable {

    /// The on-disk contract version of a C-19 config file (C-18/C-19: the NEW
    /// v1.2 files carry "v1.2").
    public static let currentContractVersion = "v1.2"

    /// The contract's FIXED defaults (C-19) — also the absent-field values.
    public static let `default` = GradingConfig()

    // MARK: The bounds (C-19 — contractual, not advisory)

    /// `toleranceCents` ∈ [10, 50] — the ±50 default is D-22's; ±25/±10 are
    /// the canonical presets. A tolerance that grades every off note a hit is
    /// a dishonest grade, so the UI cannot widen past the loosest preset.
    public static let toleranceCentsRange = 10...50
    /// `onsetGrace_ms` ∈ [80, 120] (C-5's band), default 100.
    public static let onsetGrace_msRange = 80...120
    /// `vibratoExtentCents` ∈ [10, 100], default 50 — the accepted ± swing
    /// around the note's MEAN pitch (vibrato is mean-centered, C-19).
    public static let vibratoExtentCentsRange = 10...100
    /// `breathGate_db` ∈ [-90, -30], default -60 — frames below it are
    /// UNVOICED for grading (a breath is silence, not a sung pitch).
    public static let breathGate_dbRange = -90.0...(-30.0)
    /// `goldenNoteBonus` ∈ [1.0, 1.5], default 1.1 — the multiplier on a
    /// golden note's contribution (C-4: UltraStar `*` notes).
    public static let goldenNoteBonusRange = 1.0...1.5
    /// `countIn_beats` ∈ [0, 8], default 4.
    public static let countIn_beatsRange = 0...8
    /// The weights-sum rule: 1.0 ± 0.001, checked — never normalized.
    public static let weightSumTolerance = 0.001

    /// How much help a session shows (C-19's four exact strings — the
    /// vocabulary is contractual so a session's difficulty is comparable).
    public enum GuideLevel: String, Codable, Sendable, CaseIterable {
        case ribbonPlusNotes = "ribbon+notes"
        case ribbon = "ribbon"
        case notes = "notes"
        case none = "none"
    }

    // MARK: The fields (the property names ARE the JSON keys, C-19)

    public var contractVersion: String
    /// int [10, 50], default 50. Out-of-range values are CLAMPED for grading
    /// and REPORTED (C-19) — see `clampedForGrading()`.
    public var toleranceCents: Int
    /// bool, default true — a pitch an exact octave from the reference folds
    /// to it (equivalence CLASSES, not tolerance widening: fold THEN measure).
    public var octaveEquivalence: Bool
    /// int [80, 120], default 100 — pitch deviation inside the first
    /// `onsetGrace_ms` of a note is not scored (the sung glide through a note
    /// boundary is physiology, not error).
    public var onsetGrace_ms: Int
    /// int [10, 100], default 50 — vibrato is measured MEAN-CENTERED: the
    /// note's mean pitch is the reference for its deviation, and this is the
    /// accepted ± swing around that mean.
    public var vibratoExtentCents: Int
    /// float [-90, -30], default -60 — frames below this `loudness_db` are
    /// UNVOICED for grading.
    public var breathGate_db: Double
    /// the three components, summing to 1.0 ± 0.001 (checked, never
    /// normalized — a config that does not sum is REJECTED).
    public var weights: GradingWeights
    /// float [1.0, 1.5], default 1.1.
    public var goldenNoteBonus: Double
    /// one of the four exact strings, default "ribbon+notes".
    public var guideLevel: GuideLevel
    /// int [0, 8], default 4.
    public var countIn_beats: Int
    /// bool, default false.
    public var metronome: Bool

    public init(contractVersion: String = GradingConfig.currentContractVersion,
                toleranceCents: Int = 50,
                octaveEquivalence: Bool = true,
                onsetGrace_ms: Int = 100,
                vibratoExtentCents: Int = 50,
                breathGate_db: Double = -60.0,
                weights: GradingWeights = GradingWeights(),
                goldenNoteBonus: Double = 1.1,
                guideLevel: GuideLevel = .ribbonPlusNotes,
                countIn_beats: Int = 4,
                metronome: Bool = false) {
        self.contractVersion = contractVersion
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
    }

    // MARK: Codable (C-19's absence rule: every key is OPTIONAL in a file —
    // ABSENT ⇒ the default applies. Encoding writes every key.)

    private enum CodingKeys: String, CodingKey {
        case contractVersion, toleranceCents, octaveEquivalence, onsetGrace_ms
        case vibratoExtentCents, breathGate_db, weights, goldenNoteBonus
        case guideLevel, countIn_beats, metronome
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            contractVersion: try container.decodeIfPresent(String.self, forKey: .contractVersion)
                ?? GradingConfig.currentContractVersion,
            toleranceCents: try container.decodeIfPresent(Int.self, forKey: .toleranceCents) ?? 50,
            octaveEquivalence: try container.decodeIfPresent(Bool.self, forKey: .octaveEquivalence) ?? true,
            onsetGrace_ms: try container.decodeIfPresent(Int.self, forKey: .onsetGrace_ms) ?? 100,
            vibratoExtentCents: try container.decodeIfPresent(Int.self, forKey: .vibratoExtentCents) ?? 50,
            breathGate_db: try container.decodeIfPresent(Double.self, forKey: .breathGate_db) ?? -60.0,
            weights: try container.decodeIfPresent(GradingWeights.self, forKey: .weights) ?? GradingWeights(),
            goldenNoteBonus: try container.decodeIfPresent(Double.self, forKey: .goldenNoteBonus) ?? 1.1,
            guideLevel: try container.decodeIfPresent(GuideLevel.self, forKey: .guideLevel) ?? .ribbonPlusNotes,
            countIn_beats: try container.decodeIfPresent(Int.self, forKey: .countIn_beats) ?? 4,
            metronome: try container.decodeIfPresent(Bool.self, forKey: .metronome) ?? false)
    }
}

// MARK: - The weights-sum rejection + the clamp-and-report posture

/// C-19: a config whose weights do not sum to 1.0 ± 0.001 is REJECTED —
/// never silently normalized.
public enum GradingConfigError: Error, Equatable {
    case weightsDoNotSum(sum: Double)
}

/// What `clampedForGrading()` changed, REPORTED (never silent).
public struct GradingConfigClampReport: Equatable, Sendable {
    /// The field names that were clamped into their contract bounds, in the
    /// order the clamps ran (e.g. `["toleranceCents"]`).
    public var clampedFields: [String]
    /// One plain-language line per clamp (the UI shows these; a session's
    /// honesty about its own config starts here).
    public var notes: [String]

    public init(clampedFields: [String] = [], notes: [String] = []) {
        self.clampedFields = clampedFields
        self.notes = notes
    }
}

extension GradingConfig {

    /// The config AS GRADED: clamped into C-19's bounds and checked against
    /// the weights-sum rule.
    ///
    /// - Returns: the clamped config (the grader embeds THIS one into
    ///   `SessionResult.config`, by value, so a session records what actually
    ///   graded it) + the clamp report.
    /// - Throws: `GradingConfigError.weightsDoNotSum` — C-19 rejects the
    ///   config instead of normalizing it.
    public func clampedForGrading() throws -> (config: GradingConfig, report: GradingConfigClampReport) {
        let sum = weights.sum
        guard abs(sum - 1.0) <= GradingConfig.weightSumTolerance else {
            throw GradingConfigError.weightsDoNotSum(sum: sum)
        }

        var clamped = self
        var report = GradingConfigClampReport()

        func clamp<T: Comparable>(_ value: T, into range: ClosedRange<T>,
                                  _ field: String, _ note: String) -> T {
            guard value < range.lowerBound || value > range.upperBound else { return value }
            report.clampedFields.append(field)
            report.notes.append(note)
            return min(max(value, range.lowerBound), range.upperBound)
        }

        clamped.toleranceCents = clamp(toleranceCents, into: GradingConfig.toleranceCentsRange,
                                       "toleranceCents",
                                       "toleranceCents \(toleranceCents) is outside C-19's [10, 50] — it was clamped to the nearest bound and the session records the clamped value.")
        clamped.onsetGrace_ms = clamp(onsetGrace_ms, into: GradingConfig.onsetGrace_msRange,
                                      "onsetGrace_ms",
                                      "onsetGrace_ms \(onsetGrace_ms) is outside C-19's [80, 120] — it was clamped to the nearest bound.")
        clamped.vibratoExtentCents = clamp(vibratoExtentCents, into: GradingConfig.vibratoExtentCentsRange,
                                           "vibratoExtentCents",
                                           "vibratoExtentCents \(vibratoExtentCents) is outside C-19's [10, 100] — it was clamped to the nearest bound.")
        clamped.breathGate_db = clamp(breathGate_db, into: GradingConfig.breathGate_dbRange,
                                      "breathGate_db",
                                      "breathGate_db \(breathGate_db) is outside C-19's [-90, -30] — it was clamped to the nearest bound.")
        clamped.goldenNoteBonus = clamp(goldenNoteBonus, into: GradingConfig.goldenNoteBonusRange,
                                        "goldenNoteBonus",
                                        "goldenNoteBonus \(goldenNoteBonus) is outside C-19's [1.0, 1.5] — it was clamped to the nearest bound.")
        clamped.countIn_beats = clamp(countIn_beats, into: GradingConfig.countIn_beatsRange,
                                      "countIn_beats",
                                      "countIn_beats \(countIn_beats) is outside C-19's [0, 8] — it was clamped to the nearest bound.")

        return (clamped, report)
    }
}
