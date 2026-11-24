import Foundation
import EngineCore

// ImportProgressContract (J-201) — INTERIM C-8 types (CONTRACTS v1.0, L-203).
//
// Paul's EngineCore does not carry the v1.0 C-8 types yet (P-201..P-205 are
// unclaimed). Everything here — names, raw values, semantics — matches
// CONTRACTS.md v1.0 §C-8 VERBATIM, so when his merge lands, the J-lane swap is
// a type re-import with zero UI changes (the J-101 interim-presets precedent;
// the swap DELETES this file, and the pre-ordained name collision is resolved
// by the swap itself, exactly like the M1 presets ladder).
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

/// C-8 rawValues STABLE FOREVER (persisted in UI state/logs).
public enum ImportStage: String, Sendable, CaseIterable {
    /// Container decode → 44.1 kHz mix (P-203).
    case decoding
    /// Chunked two-stem separation (P-201/P-202).
    case separating
    /// ALAC stem encode + SongBundle assembly (P-204).
    case assembling
}

public struct ImportProgress: Sendable, Equatable {
    public let stage: ImportStage
    /// OVERALL import fraction in [0, 1]; monotonic; 1.0 only at completion.
    public let fraction: Double
    /// Engine-authored optional human-readable detail (e.g. "chunk 7/40").
    public let detail: String?

    public init(stage: ImportStage, fraction: Double, detail: String? = nil) {
        self.stage = stage
        self.fraction = fraction
        self.detail = detail
    }
}

public typealias ImportProgressHandler = @Sendable (ImportProgress) -> Void

/// Additive conformance over EngineAPI (C-3). Implemented by Paul's real
/// engine AND the J-201 scripted mock, so the progress UI builds against the
/// contract shape from day one.
public protocol ProgressReportingEngine: EngineAPI {
    /// Set BEFORE calling importAudio/separate; nil clears. Called on an
    /// ARBITRARY thread/queue — the handler must not block or touch UI
    /// directly. Last handler wins.
    func setImportProgressHandler(_ handler: ImportProgressHandler?)
}

// MARK: - ImportProgressTracker (UI-side enforcement of the C-8 guarantees)

/// Guards the OVERALL fraction the engine reports before it reaches the UI.
///
/// C-8 makes the ENGINE responsible for monotonicity and the 1.0-only-at-
/// completion rule; this tracker is the UI-side defense that upholds the
/// contract even if an engine build regresses — a non-monotonic, out-of-range,
/// or out-of-order event is clamped/rejected and COUNTED (surfaced on the
/// debug screen, never silently swallowed: D-12 honesty).
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
