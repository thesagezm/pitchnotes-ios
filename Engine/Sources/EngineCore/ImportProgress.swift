import Foundation

// C-8 · Import progress & cancellation (CONTRACTS.md v1.0, FROZEN 2026-11-22
// UTC — L-203, D-32.3). Types below are VERBATIM from the contract.
//
// Long-running engine calls (`importAudio`, `separate`, the future note-track
// paths) report staged progress and cancel cooperatively. EngineAPI signatures
// are UNCHANGED — this is an additive protocol so v0.x conformers keep compiling.

/// RawValues STABLE FOREVER (additive only). Persisted in UI state/logs.
public enum ImportStage: String, Sendable, CaseIterable {
    case decoding     // container decode → 44.1 kHz mix (P-203)
    case separating   // chunked two-stem separation (P-201/P-202)
    case assembling   // ALAC stem encode + SongBundle assembly (P-204)
}

public struct ImportProgress: Sendable, Equatable {
    public let stage: ImportStage
    /// OVERALL import fraction in [0, 1]; MONOTONIC within one import call
    /// (never decreases; 1.0 only at completion — P-202 AC).
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

/// Additive conformance over EngineAPI (C-3). Implemented by Paul's real engine
/// AND MockEngine (J-201 builds the progress UI against the mock from day one).
public protocol ProgressReportingEngine: EngineAPI {
    /// Set BEFORE calling importAudio/separate; nil clears. Called on an ARBITRARY
    /// thread/queue — the handler must not block or touch UI directly. Last
    /// handler wins; the engine owns no delivery cadence guarantees beyond
    /// "monotonic fraction, at least one call per stage".
    func setImportProgressHandler(_ handler: ImportProgressHandler?)
}

/// Engine-side helper for the C-8 fraction-monotonicity guarantee: clamps the
/// reported fraction to [0, 1] and to be >= the highest fraction already emitted
/// by this emitter. The real engine (P-201/P-202) and MockEngine both drive their
/// handlers through this so "progress never decreases" holds even when per-chunk
/// estimates wobble.
public final class ImportProgressEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ImportProgressHandler?
    private var highestEmitted: Double = -1

    public init() {}

    public func setHandler(_ handler: ImportProgressHandler?) {
        lock.lock()
        self.handler = handler
        // Resetting the handler starts a new import call — fractions may restart.
        self.highestEmitted = -1
        lock.unlock()
    }

    /// Emits `progress` (clamped to [0, 1] and monotonic vs. what was already
    /// emitted) if a handler is set. Call sites still own the "at least one call
    /// per stage" obligation.
    public func emit(_ progress: ImportProgress) {
        lock.lock()
        let handler = self.handler
        let fraction = min(max(progress.fraction, 0), 1)
        let monotonic = max(fraction, highestEmitted)
        self.highestEmitted = monotonic
        lock.unlock()
        guard let handler else { return }
        handler(ImportProgress(stage: progress.stage, fraction: monotonic, detail: progress.detail))
    }
}
