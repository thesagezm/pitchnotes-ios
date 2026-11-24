import Foundation
import EngineCore

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

// MARK: - Manifest → tuning estimate (SWAP SEAM #1: EngineCore consumes)

public extension SongManifest {

    /// D-22: the recording's tuning offset, when the manifest carries one that
    /// is PRESENT and IN RANGE.
    ///
    /// Validity is decided by the ENGINE's own rules, not by a lane-local copy:
    /// for a v1.x manifest the engine's V14 (required fields + ranges) and V15
    /// (INSTRUMENTAL ⇔ hasInstrumental) decide it; a v0-era manifest is judged
    /// by its era's rules (V1–V13) — `tuning_cents` was optional since v0.1.1,
    /// so a v0.1.1 manifest MAY carry an estimate and it is honored.
    ///
    /// nil means "NO ESTIMATE" (v0-era without one, or an invalid v1.x
    /// manifest) — callers treat nil as 0/unknown. An invalid estimate is
    /// NEVER silently clamped into a plausible-looking number (D-12 honesty).
    ///
    /// SWAP SEAM #1: this replaces the lane-local `ManifestV1` decoder that
    /// existed while EngineCore lacked the v1.0 types (J-205). The engine's
    /// model + validator are now the single source of truth (D-33 principle:
    /// app mirrors engine — one semantic, never two).
    var validTuningCents: Int? {
        let report = BundleValidator.validate(manifest: self)
        let versionInvalid = report.violations.contains { $0.rule == "V14" || $0.rule == "V15" }
        guard !versionInvalid,
              let cents = tuning_cents,
              TuningPolicy.centsRange.contains(cents) else { return nil }
        return cents
    }
}
