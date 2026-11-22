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

        func emit(_ fraction: Double, _ detail: String) {
            let lo = config.progressBand.low, hi = config.progressBand.high
            let f = lo + (hi - lo) * min(1.0, max(0.0, fraction))
            progress?(ImportProgress(stage: .separating, fraction: f, detail: detail))
        }
        // C-8: "1.0 only at completion" — the final emit bypasses the band.
        func emitCompletion() {
            progress?(ImportProgress(stage: .separating, fraction: 1.0,
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
            let stems = try await engine.separate(window: win, channels: channels)

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

        emitCompletion()
        return acc
    }
}
