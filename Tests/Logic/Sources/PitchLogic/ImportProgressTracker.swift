import Foundation
import EngineCore

// ImportProgressTracker (J-201) — the UI-SIDE enforcement of the C-8
// progress guarantees. The C-8 TYPES themselves are EngineCore's
// (ImportStage / ImportProgress / ImportProgressHandler /
// ProgressReportingEngine — CONTRACTS.md v1.0 §C-8, verbatim, landed with
// Paul's M2 engine merge).
//
// SWAP SEAM #1 (executed at the paul→main gate merge): the interim lane-local
// C-8 copies that used to live in this file are GONE — this module now
// consumes EngineCore's contract types, exactly like Part / NoteTrack /
// SongManifest (one definition, no lane-local copies). The pre-ordained name
// collision was resolved by the swap itself (the J-101 interim-presets
// precedent): zero UI changes, zero view changes.
//
// The tracker stays here because it is NOT a contract type — it is the
// J-lane's defensive UI layer (D-12 honesty): the ENGINE owns monotonicity and
// the 1.0-only-at-completion rule (C-8), and this tracker upholds them even if
// an engine build regresses — a non-monotonic, out-of-range, or out-of-order
// event is clamped/rejected and COUNTED (surfaced on the debug screen, never
// silently swallowed).
//
// What v1.0 freezes (C-8):
//   · ImportStage {decoding, separating, assembling} — rawValues stable.
//   · ImportProgress {stage, fraction, detail} — fraction is the OVERALL
//     import fraction in [0, 1] (the ENGINE weights its own stages), MONOTONIC
//     within one import call, 1.0 only at completion (P-202 AC).
//   · ImportProgressHandler — called on an ARBITRARY thread/queue; must not
//     block or touch UI directly. Last handler wins.
//   · ProgressReportingEngine — additive conformance over EngineAPI; the
//     handler is set BEFORE importAudio/separate.
//   · Cancellation — the caller cancels the surrounding Task; engines check
//     Task.isCancelled between chunks and throw CancellationError(); on
//     cancellation or error the staging directory is removed and NO partial
//     bundle survives (C-2.2).

// MARK: - ImportProgressTracker (UI-side enforcement of the C-8 guarantees)

/// Guards the OVERALL fraction the engine reports before it reaches the UI.
public struct ImportProgressTracker: Sendable, Equatable {

    /// Just-under-full cap for pre-completion events (the UI bar must only
    /// read "done" on the completion event).
    public static let preCompletionCap = 0.999

    public private(set) var snapshot: ImportProgress?
    public private(set) var isComplete = false
    /// Events clamped because they would have decreased the overall fraction
    /// or hit 1.0 before completion.
    public private(set) var clippedNonMonotonicEvents = 0
    /// Events rejected outright (backwards stage, or fed after completion).
    public private(set) var rejectedEvents = 0

    private var highestStageIndex = -1
    private var lastOverall: Double = 0

    public init() {}

    /// Feed one raw engine event (`fraction` = OVERALL, per C-8); returns the
    /// enforced snapshot (unchanged when the event is rejected).
    @discardableResult
    public mutating func feed(stage: ImportStage, fraction: Double, detail: String?) -> ImportProgress {
        if isComplete {
            rejectedEvents += 1
            return snapshot ?? ImportProgress(stage: stage, fraction: 0, detail: detail)
        }
        let index = ImportStage.allCases.firstIndex(of: stage) ?? 0
        guard index >= highestStageIndex else {
            rejectedEvents += 1
            return snapshot ?? ImportProgress(stage: stage, fraction: 0, detail: detail)
        }
        highestStageIndex = index

        var overall = min(max(fraction, 0), 1)

        // C-8: 1.0 only at completion. A pre-completion 1.0 (or overshoot) is
        // capped just under full so the UI bar reads "almost done", not done.
        var clipped = false
        if overall >= 1.0 {
            overall = Self.preCompletionCap
            clipped = true
        }
        // C-8: monotonic — never decreases.
        if overall < lastOverall {
            overall = lastOverall
            clipped = true
        }
        if clipped { clippedNonMonotonicEvents += 1 }
        lastOverall = overall

        snapshot = ImportProgress(stage: stage, fraction: overall, detail: detail)
        return snapshot!
    }

    /// Completion event — the ONLY path that produces fraction 1.0.
    @discardableResult
    public mutating func finish(detail: String? = nil) -> ImportProgress {
        let stage = snapshot?.stage ?? .assembling
        isComplete = true
        lastOverall = 1.0
        snapshot = ImportProgress(stage: stage, fraction: 1.0, detail: detail)
        return snapshot!
    }
}
