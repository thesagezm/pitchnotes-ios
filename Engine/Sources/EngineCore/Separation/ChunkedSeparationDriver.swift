import Foundation

// P-202 (M2) — Chunked overlap-add separation driver (PAUL lane, portable core:
// Linux-tested against a mock SegmentEngine; the real engine wires in at L2).
//
// D-25 (Leto, RULED): Muskey ships 4.5 s windows / 1 s overlap; our §8 plan says
// 5–10 s — the BENCHMARK decides (measured SDR/RTF/RSS, BENCHMARKS.md), this
// driver implements the mechanism both policies plug into.
//
// Why LINEAR crossfade (not equal-power): consecutive windows come from the SAME
// model on overlapping input, so stem content in the overlap region is highly
// CORRELATED. Equal-power weights sum to √2 for identical signals (+3 dB bumps
// at every boundary); linear weights sum to exactly 1 — unity reconstruction for
// identical content, monotone blend for the (small) window-context differences.
// Matches the vendor's own transition-weight overlap convention.
//
// C-8 contract: progress monotonic (ImportProgressEmitter clamp), cooperative
// cancellation between windows (CancellationError), and the driver produces NO
// output state the caller could mistake for a bundle on cancel — outputs are
// returned only on success; staging/bundle discipline stays with the caller
// (P-201c pattern: staging dir removed on any failure).
//
// L2 progress mapping (P-202): the driver owns the C-8 `separating` band and
// is its SINGLE writer. An engine MAY report within-window progress (the
// vendor's own per-stage callback); the driver scales it into that window's
// slice of the band, so the user sees movement during a long window instead of
// a frozen bar. The driver never emits 1.0 unless it owns completion
// (`Config.emitCompletion` — the engine sets it false when it still has to
// stage the stems on disk after the driver returns).

/// Tunable chunking policy (D-25: both recipes benchmarked, pick by measurement).
public struct ChunkPolicy: Sendable, Equatable {
    /// Window length in seconds (the segment the engine sees per call).
    public let windowSeconds: Double
    /// Overlap between consecutive windows in seconds (< windowSeconds).
    public let overlapSeconds: Double
    public let sampleRate: Int

    public init(windowSeconds: Double, overlapSeconds: Double, sampleRate: Int = 44100) {
        self.windowSeconds = windowSeconds
        self.overlapSeconds = overlapSeconds
        self.sampleRate = sampleRate
    }

    /// Our §8 5–10 s plan, concrete: 8 s windows / 2 s overlap.
    public static let planDefault = ChunkPolicy(windowSeconds: 8.0, overlapSeconds: 2.0)
    /// Muskey recipe (D-25 benchmark arm): 4.5 s / 1 s.
    public static let muskeyRecipe = ChunkPolicy(windowSeconds: 4.5, overlapSeconds: 1.0)

    public var windowSamples: Int { Int(windowSeconds * Double(sampleRate)) }
    public var overlapSamples: Int { Int(overlapSeconds * Double(sampleRate)) }
    public var hopSamples: Int { windowSamples - overlapSamples }

    public func validated() throws {
        guard windowSamples > overlapSamples, overlapSamples >= 0 else {
            throw EngineError.contractViolation(
                "ChunkPolicy: window (\(windowSamples) samples) must exceed overlap (\(overlapSamples) samples)")
        }
    }
}

/// Portable thermal pacing state (ProcessInfo.thermalState is darwin-only —
/// Linux builds provide `.nominal`; the app wires the real provider at L2).
public enum ThermalState: Sendable, Equatable {
    case nominal, fair, serious, critical
}

/// One window of the staged mix in → per-part stems out. Implemented by
/// DemucsEngine at L2 (vendor inference per window, internal 7.8 s segments
/// owned by the vendor); MockEngine implements it for Linux tests.
public protocol SegmentEngine: Sendable {
    /// `window` is channel-major-interleaved f32 at the policy sample rate.
    /// Returned arrays per part must all have the same length as the window
    /// (per-channel framing: `samples = frames * channels`, interleaved).
    func separate(window: [Float], channels: Int) async throws -> [Part: [Float]]

    /// Same call, with WITHIN-window progress: `fraction` is the engine's own
    /// progress inside THIS window ([0, 1]) and `detail` is a human-readable
    /// note (the vendor's stage name). The driver scales it into this window's
    /// slice of the C-8 progress band — the driver stays the single writer of
    /// the band, so the engine never picks absolute fractions.
    ///
    /// The closure is @escaping: an engine hands it to its native inference
    /// callback, which outlives the call (the vendor calls back from the
    /// inference thread). Protocol requirements may declare @escaping
    /// explicitly — without it the parameter would be implicitly non-escaping
    /// and could not be stored by the implementation (caught by the macOS
    /// compile of P-202 L2).
    ///
    /// Default implementation ignores the progress (engines with no
    /// sub-window signal, e.g. the Linux mock) — window-granular progress is
    /// then what the user sees.
    func separate(window: [Float], channels: Int,
                  progress: @escaping @Sendable (Double, String) -> Void) async throws -> [Part: [Float]]
}

public extension SegmentEngine {
    func separate(window: [Float], channels: Int,
                  progress: @escaping @Sendable (Double, String) -> Void) async throws -> [Part: [Float]] {
        _ = progress
        return try await separate(window: window, channels: channels)
    }
}

/// Streaming overlap-add driver: windows the staged mix, calls the engine per
/// window, linearly blends the overlap regions per part, reports monotonic
/// C-8 progress, paces against thermal state between windows, and cancels
/// cooperatively (CancellationError before ANY result exists).
public final class ChunkedSeparationDriver: @unchecked Sendable {

    public struct Config: Sendable {
        /// Progress is mapped into the C-8 `separating` band [0.05, 0.95].
        public var progressBand: (low: Double, high: Double) = (0.05, 0.95)
        /// Between-window pacing delays per thermal state (seconds).
        public var paceDelays: [ThermalState: Double] = [
            .nominal: 0.0, .fair: 0.0, .serious: 0.5, .critical: 2.0,
        ]
        /// Injectable sleep for unit tests (default: real Task.sleep).
        public var sleeper: @Sendable (Double) async throws -> Void = { s in
            try await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
        }
        /// When true (default) the driver emits the C-8 completion fraction
        /// 1.0 itself. Set false when the CALLER owns the final 1.0 because
        /// work continues after the driver returns (the engine still has to
        /// stage the stems on disk — C-8: "1.0 only at completion").
        public var emitCompletion: Bool = true

        public init() {}
    }

    private let policy: ChunkPolicy
    private let config: Config
    private let thermalProvider: @Sendable () -> ThermalState
    private let progress: (@Sendable (ImportProgress) -> Void)?

    /// - Parameters:
    ///   - policy: window/overlap/sampleRate (validated up front).
    ///   - thermalProvider: injected so Linux tests can drive mock states
    ///     (darwin app wires `ProcessInfo.processInfo.thermalState` at L2).
    ///   - progress: C-8 handler (fraction clamped monotonic here — the driver
    ///     is the single writer for its own band).
    public init(policy: ChunkPolicy,
                config: Config = Config(),
                thermalProvider: @escaping @Sendable () -> ThermalState = { .nominal },
                progress: (@Sendable (ImportProgress) -> Void)? = nil) throws {
        try policy.validated()
        self.policy = policy
        self.config = config
        self.thermalProvider = thermalProvider
        self.progress = progress
    }

    /// Runs chunked separation over the whole staged mix. Returns per-part
    /// full-length interleaved stems ONLY on success; throws CancellationError
    /// if the surrounding task is cancelled (checked before/after each window).
    /// - Parameters:
    ///   - audio: interleaved f32 mix, `frames * channels` samples.
    ///   - channels: 1 (mono) or 2 (stereo) per D-8.
    public func run(audio: [Float], channels: Int, engine: any SegmentEngine) async throws -> [Part: [Float]] {
        let frames = audio.count / channels
        guard frames * channels == audio.count, channels >= 1, channels <= 2 else {
            throw EngineError.contractViolation(
                "ChunkedSeparationDriver: audio \(audio.count) samples not frames×channels (channels \(channels))")
        }
        guard frames > 0 else {
            throw EngineError.contractViolation("ChunkedSeparationDriver: empty audio")
        }
        let window = policy.windowSamples
        let hop = policy.hopSamples

        // Window plan: starts advance by `hop` while a full window fits; the
        // tail window is truncated (shorter, still ≥ overlap against the
        // previous window because hop < window). Every frame covered ≥ once.
        var starts: [Int] = []
        if frames <= window {
            starts = [0]
        } else {
            var s = 0
            while s + window < frames {
                starts.append(s)
                s += hop
            }
            starts.append(s) // tail window: s + window >= frames → truncate to frames
        }

        var acc: [Part: [Float]] = [:] // accumulated (blended) output, interleaved
        var parts: Set<Part>? = nil    // key set consistency guard
        var doneFrames = 0             // input frames already ingested

        let bandLow = config.progressBand.low
        let bandHigh = config.progressBand.high
        let progressHandler = progress

        func emit(_ fraction: Double, _ detail: String) {
            let f = bandLow + (bandHigh - bandLow) * min(1.0, max(0.0, fraction))
            progressHandler?(ImportProgress(stage: .separating, fraction: f, detail: detail))
        }
        // C-8: "1.0 only at completion" — the final emit bypasses the band.
        func emitCompletion() {
            progressHandler?(ImportProgress(stage: .separating, fraction: 1.0,
                                            detail: "separation complete"))
        }

        emit(0.0, "chunked separation: \(starts.count) window(s)")

        for (idx, s) in starts.enumerated() {
            try Task.checkCancellation()

            // Thermal pacing BEFORE the window (nominal/fair → no delay).
            let delay = config.paceDelays[thermalProvider()] ?? 0.0
            if delay > 0 {
                emit(Double(doneFrames) / Double(frames), "thermal pacing \(delay)s")
                try await config.sleeper(delay)
                try Task.checkCancellation()
            }

            let wLen = min(window, frames - s)
            let win = Array(audio[s * channels ..< (s + wLen) * channels])

            // Within-window progress: the engine reports [0, 1] INSIDE this
            // window; the driver scales it into this window's slice of the
            // band (the driver stays the single writer of the band, so the
            // engine never emits an absolute fraction).
            //
            // The slice starts at the frames ALREADY INGESTED (doneFrames),
            // NOT at the window's own start: consecutive windows OVERLAP, so
            // the next window's start lies BEFORE the previous window's end.
            // Slicing from the window start would make the fraction DECREASE
            // at every boundary (C-8 monotonicity). The slice therefore spans
            // exactly the NEW frames this window contributes
            // [doneFrames, s + wLen) — the hop, not the window length — and
            // its end equals the post-window emit below.
            let windowStart = Double(doneFrames) / Double(frames)
            let windowSpan = Double(s + wLen - doneFrames) / Double(frames)
            let stems = try await engine.separate(window: win, channels: channels) { v, detail in
                let vc = min(1.0, max(0.0, v))
                let jobFraction = windowStart + windowSpan * vc
                let f = bandLow + (bandHigh - bandLow) * jobFraction
                progressHandler?(ImportProgress(stage: .separating, fraction: f, detail: detail))
            }

            let keys = Set(stems.keys)
            if let p = parts {
                guard keys == p else {
                    throw EngineError.contractViolation(
                        "ChunkedSeparationDriver: engine returned inconsistent part keys \(keys.sorted()) vs \(p.sorted())")
                }
            }
            parts = keys
            for (part, stem) in stems {
                guard stem.count == wLen * channels else {
                    throw EngineError.contractViolation(
                        "ChunkedSeparationDriver: engine returned \(stem.count) samples for a \(wLen * channels)-sample window (part \(part))")
                }
            }

            if acc.isEmpty {
                for (part, stem) in stems { acc[part] = stem }
            } else {
                // Blend region: accumulated coverage beyond this window's start.
                let accLen = (acc.first?.value.count ?? 0) / channels
                let overlap = accLen - s
                guard overlap >= 0, overlap <= wLen else {
                    throw EngineError.contractViolation(
                        "ChunkedSeparationDriver: window plan gap — acc \(accLen) frames vs start \(s)")
                }
                for (part, stem) in stems {
                    var out = acc[part]!
                    // Linear crossfade over the overlap: w_prev = 1 - t, w_inc = t.
                    for i in 0..<overlap {
                        let t = Double(i) / Double(overlap)
                        for c in 0..<channels {
                            let idx = (i * channels) + c
                            out[s * channels + idx] =
                                out[s * channels + idx] * Float(1 - t) + stem[idx] * Float(t)
                        }
                    }
                    if stem.count > overlap * channels {
                        out.append(contentsOf: stem[(overlap * channels)...])
                    }
                    acc[part] = out
                }
            }

            doneFrames = s + wLen
            emit(min(1.0, Double(doneFrames) / Double(frames)),
                 "window \(idx + 1)/\(starts.count)")
        }

        try Task.checkCancellation()

        // Trim: last window's truncated plan guarantees acc length == frames.
        for (part, stem) in acc {
            let n = frames * channels
            guard stem.count >= n else {
                throw EngineError.contractViolation(
                    "ChunkedSeparationDriver: under-coverage for \(part) (\(stem.count) < \(n))")
            }
            acc[part] = Array(stem[0..<n])
        }

        if config.emitCompletion {
            emitCompletion()
        }
        return acc
    }
}
