import Foundation
import EngineCore

// SeparationTimer (J-206, session 7) — the SEPARATION PASS, measured from the
// C-8 progress stream.
//
// `import EngineCore` IS LOAD-BEARING: `ImportStage` is EngineCore's C-8 type
// once the swap seam #1 deletes the interim lane-local copy, so without this
// import this file compiles on the pre-swap branches (where PitchLogic
// defines the type itself) and FAILS on the post-swap ones. The probe
// (jess-swap-probe-v5, run 45096751903) caught exactly that — a latent
// gate-time red that no pre-swap build could ever surface.
//
// WHY THE MEASUREMENT CHANGED (and why it is not a detail):
// The first implementation measured the separation by wrapping the
// `separate()` call in wall-clock time. That works only while the app drives
// the frozen C-3 pair (`importAudio` → `separate`) — and it OVERSTATES the
// separation, because on the mock the bundle assembly happens INSIDE
// `separate()`, so the measured window silently included the ALAC encode.
// Paul's real engine publishes atomically (`importSong`, X-209), where the
// separation is not an app-visible call at all. The number therefore has to
// come from the one signal BOTH paths share: the C-8 stage stream.
//
// C-8 guarantees "at least one call per stage", so on a successful import the
// band is always observable:
//
//     decoding ──────────► separating ──────────► assembling
//                          ▲ band opens           ▲ band closes
//
// The clock is INJECTED (the caller passes the timestamp), so this type stays
// pure and unit-testable — no `Date()` inside, no clock to mock.
//
// HONESTY (D-12): if the band is never observed, `separationWallTime_s` is
// nil — "not measured" — never a fabricated 0.0, which would read as
// "infinitely fast" in the RTF line.

/// Measures the separation pass from the C-8 progress stages.
public struct SeparationTimer: Equatable, Sendable {

    /// What one progress event did to the separation band.
    public enum BandTransition: Equatable, Sendable {
        /// The event did not touch the band.
        case none
        /// The band OPENED — this was the first `.separating` event.
        case opened
        /// The band CLOSED — this was the first `.assembling` event after the
        /// band had opened.
        case closed
    }

    /// When the separation band opened (the first `.separating` event).
    public private(set) var separationStartedAt: Date?
    /// When the separation band closed (the first `.assembling` event after
    /// it opened).
    public private(set) var separationEndedAt: Date?

    public init() {}

    /// Observe one C-8 progress event.
    ///
    /// - Returns: what the event did to the band, so the caller can sample
    ///   the thermal state exactly at the band edges (the AC asks for the
    ///   thermal state at the START and END of the pass).
    @discardableResult
    public mutating func observe(stage: ImportStage, at date: Date) -> BandTransition {
        switch stage {
        case .decoding:
            return .none
        case .separating:
            guard separationStartedAt == nil else { return .none }
            separationStartedAt = date
            return .opened
        case .assembling:
            guard separationStartedAt != nil, separationEndedAt == nil else { return .none }
            separationEndedAt = date
            return .closed
        }
    }

    /// The separation pass's wall time in seconds, or nil when the band was
    /// never observed (an engine that broke C-8 — never a fabricated zero).
    public var separationWallTime_s: Double? {
        guard let start = separationStartedAt,
              let end = separationEndedAt,
              end >= start else { return nil }
        return end.timeIntervalSince(start)
    }

    /// Whether the band was observed at all (both edges).
    public var isMeasured: Bool { separationWallTime_s != nil }
}
