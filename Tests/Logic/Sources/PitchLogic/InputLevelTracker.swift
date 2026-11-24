import Foundation

/// InputLevelTracker (J-102) — the REAL input-level meter value, as a pure,
/// unit-testable value type.
///
/// WHY THIS EXISTS (the M1 device demo, 2026-11-22): the "Input level" meter
/// read a deterministic MOCK wobble (0.25–0.75 at 10 Hz, `MockMicLevelSource`)
/// no matter what the singer did, so the meter looked "very sensitive" while
/// it was in fact saying nothing at all. The real capture (P-104, X-011a) is
/// ALREADY live on the ribbon path — the engine hands us the chunk's RMS
/// dBFS in every frame (C-2.4 `loudness_db`). This tracker turns that into the
/// meter's 0…1 value, so the reading is the singer's.
///
/// THE MAPPING (D-12 honesty — the anchors are fixed and the ends are exact):
///   · floor  −60 dBFS ⇒ 0
///   · ceiling   0 dBFS ⇒ 1
///   · linear in dB between the anchors, clamped outside them
///   · a non-finite loudness reads as 0 (never a fabricated level)
///
/// THE SMOOTHING (per frame — the ribbon's frames are ~16 ms apart):
///   · attack 0.5 — the meter reaches a new peak quickly, so a sung note
///     shows up instead of being averaged away
///   · release 0.15 — it falls slowly, so the meter does not flicker between
///     syllables
///
/// Pure on purpose: it lives in PitchLogic so the logic-tests can pin the
/// arithmetic on Linux (no AppKit/SwiftUI/audio hardware), and the App layer
/// only feeds it a number.
public struct InputLevelTracker: Sendable, Equatable {

    /// dBFS at which the meter reads 0 (below this: no signal).
    public static let floorDB: Double = -60
    /// dBFS at which the meter reads 1 (at or above this: full scale).
    public static let ceilingDB: Double = 0
    /// Smoothing coefficient applied when the level RISES.
    public static let attack: Double = 0.5
    /// Smoothing coefficient applied when the level FALLS.
    public static let release: Double = 0.15

    /// The current smoothed level, 0…1.
    public private(set) var level: Double = 0

    public init() {}

    /// Maps one frame's loudness to a target level — pure, no state.
    public static func normalized(loudnessDB: Double) -> Double {
        guard loudnessDB.isFinite else { return 0 }
        let clamped = min(max(loudnessDB, floorDB), ceilingDB)
        return (clamped - floorDB) / (ceilingDB - floorDB)
    }

    /// Feeds one frame and returns the new smoothed level.
    @discardableResult
    public mutating func ingest(loudnessDB: Double) -> Double {
        let target = Self.normalized(loudnessDB: loudnessDB)
        let coefficient = target > level ? Self.attack : Self.release
        level += (target - level) * coefficient
        level = min(max(level, 0), 1)
        return level
    }

    /// Returns to silence (an interruption, a permission change, a reset).
    public mutating func reset() {
        level = 0
    }
}
