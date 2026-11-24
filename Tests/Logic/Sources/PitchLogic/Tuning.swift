import Foundation

// Tuning reference policy (D-22, J-205): old SDA recordings often sit
// systematically sharp/flat of A440. The DEFAULT behavior offsets the
// REFERENCE, never the stored audio (audio stays byte-true). The recording's
// estimated offset (`tuning_cents` in a v1.0 manifest, produced at P-207) is
// what grading adds to the reference (J-401) and what the ribbon applies to
// its note-name + cents reference (M2 wiring below).

/// Per-song user override of the tuning reference (persisted in the bundle
/// index, D-4 v0 — UI-owned state, not part of the C-2 manifest).
public struct TuningOverride: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        /// Follow the recording's estimated `tuning_cents` (D-22 default).
        case recording
        /// Ignore the estimate — grade against plain A440.
        case forceA440
        /// User-supplied offset in cents (clamped to the manifest range).
        case manual
    }

    public let mode: Mode
    /// Only meaningful for `.manual`; [−50, +50], + = sharp (D-22 clamp).
    public let manualCents: Int?

    public init(mode: Mode, manualCents: Int? = nil) {
        self.mode = mode
        self.manualCents = manualCents
    }
}

public enum TuningPolicy {

    /// D-22 clamp for manual overrides (matches the manifest field range).
    public static let centsRange: ClosedRange<Int> = -50...50

    /// Resolves the effective reference offset for a song.
    /// - detected: the manifest's `tuning_cents` (0 when unknown/v0-era).
    /// - override: nil ⇒ `.recording` default.
    public static func resolvedCents(detected: Int, override: TuningOverride?) -> Int {
        switch override?.mode {
        case .forceA440:
            return 0
        case .manual:
            return min(max(override?.manualCents ?? 0, centsRange.lowerBound), centsRange.upperBound)
        case .recording, .none:
            return min(max(detected, centsRange.lowerBound), centsRange.upperBound)
        }
    }
}

/// What the UI renders for one song's tuning state ("+32c sharp — reference
/// adjusted"). The chip appears only when the resolved offset is large enough
/// to matter — the estimator itself reports 0 below 10¢ (D-22 / dettato
/// `MIN_CENTS`), so the default threshold matches that floor.
public struct TuningDisplay: Equatable, Sendable {
    public static let defaultChipThreshold: Int = 10

    public let resolvedCents: Int
    public let showsChip: Bool

    public init(resolvedCents: Int, chipThreshold: Int = TuningDisplay.defaultChipThreshold) {
        self.resolvedCents = resolvedCents
        self.showsChip = abs(resolvedCents) >= chipThreshold
    }

    /// D-22 §2 wording: "+32c sharp — reference adjusted" (or "−35c flat …").
    /// Empty when the chip is off — callers hide the chip instead of a label.
    public var label: String {
        guard showsChip else { return "" }
        let sign = resolvedCents > 0 ? "+" : "−"
        let direction = resolvedCents > 0 ? "sharp" : "flat"
        return "\(sign)\(abs(resolvedCents))c \(direction) — reference adjusted"
    }
}
