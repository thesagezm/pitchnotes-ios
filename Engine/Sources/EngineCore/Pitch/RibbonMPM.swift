import Foundation

// Causal ribbon pitch engine (P-102, PAUL lane) — Swift implementation of
// McLeod Pitch Method (McLeod & Wyvill 2005, published algorithm; independent
// implementation, no code copied). The VENDORED sevagh/pitch-detection C++
// (D-19 intake) is the CI-spike reference (Tests/Spikes/ribbon_real.py) and
// compiles into the app via Leto wiring (X-009); this Swift path gives the
// portable core the same zero-lookahead ribbon for Linux tests + the P-105
// facade's synthetic-stream tests, and binds to vDSP/Accelerate later if
// profiling demands it.
//
// Difference vs the vendored FFT path (documented, not silent): the vendored
// autocorrelation is CIRCULAR (FFT of the raw window), which biases
// non-integer periods (vendor README engineering note). This implementation
// computes the NSDF DIRECTLY from the McLeod definition — no circularity, no
// leakage — at O(W²/2) MACs per frame (W=1024 ⇒ ~0.5 M MAC/frame at a 16 ms
// hop ⇒ RTF ≈ 0.02–0.03 native, far under the 0.1 budget; measure at P-106).

public enum RibbonSpec {
    /// Analysis window in samples (64 ms @16 kHz — ribbon latency tradeoff;
    /// the spike documents the 128 ms window's better sweep accuracy).
    public static let window = 1024
    /// Emission hop (16 ms — contract C-2.4 grid).
    public static let hop = 256
    public static let sampleRate = 16_000
    /// Peak acceptance relative to the highest NSDF peak (upstream constant).
    public static let cutoff = 0.93
    /// Smallest period analyzed: SR/2/window ⇒ highest ribbon pitch 250 Hz
    /// at W=1024? No — MPM analyzes lags up to window/2: max pitch =
    /// SR/(window/2) = 31.25 Hz; the effective floor is the MPM low cutoff.
    public static let lowerPitchCutoff = 80.0
}

/// One causal ribbon frame: `hz` is the raw MPM estimate (0 when no peak /
/// below the 80 Hz floor — the caller fuses voicing with the VAD gate);
/// `clarity` is the NSDF value at the chosen peak, in [0, 1] — the ribbon's
/// confidence signal (MPM has NO voicing decision; P-103/P-104 own that).
public struct RibbonFrame: Sendable, Equatable {
    public let t: Double
    public let hz: Double
    public let clarity: Double

    public init(t: Double, hz: Double, clarity: Double) {
        self.t = t
        self.hz = hz
        self.clarity = clarity
    }
}

/// McLeod Pitch Method over a fixed window: NSDF → peak picking →
/// parabolic interpolation. Deterministic, allocation-free per call
/// (buffers owned by the engine instance — reuse is the hot-path pattern
/// the vendored intake verified, D-19).
public enum MPM {
    /// Normalized square-difference function (McLeod definition), computed
    /// directly over `window` samples.
    static func computeNSDF(_ x: ArraySlice<Float>, window: Int, out: inout [Float]) {
        out.removeAll(keepingCapacity: true)
        out.reserveCapacity(window / 2)
        let base = x.startIndex
        let w = window
        var total = 0.0
        var suffix = [Double](repeating: 0, count: w + 1)
        for i in 0..<w {
            total += Double(x[base + i]) * Double(x[base + i])
        }
        // suffix[k] = sum of squares of samples k..<w
        suffix[w] = 0
        for k in stride(from: w - 1, through: 0, by: -1) {
            suffix[k] = suffix[k + 1] + Double(x[base + k]) * Double(x[base + k])
        }
        for lag in 0..<(w / 2) {
            var corr = 0.0
            let upper = w - lag
            for i in 0..<upper {
                corr += Double(x[base + i]) * Double(x[base + i + lag])
            }
            let den = (total - suffix[upper]) + suffix[lag]
            out.append(den > 1e-12 ? Float(2.0 * corr / den) : 0)
        }
    }

    /// Upstream-faithful peak picking: collect per-zero-crossing-region maxima.
    static func peakPicking(_ nsdf: [Float]) -> [Int] {
        var maxPositions: [Int] = []
        var pos = 0
        var curMaxPos = 0
        let size = nsdf.count
        while pos < (size - 1) / 3 && nsdf[pos] > 0 { pos += 1 }
        while pos < size - 1 && nsdf[pos] <= 0 { pos += 1 }
        if pos == 0 { pos = 1 }
        while pos < size - 1 {
            if nsdf[pos] > nsdf[pos - 1] && nsdf[pos] >= nsdf[pos + 1]
                && (curMaxPos == 0 || nsdf[pos] > nsdf[curMaxPos]) {
                curMaxPos = pos
            }
            pos += 1
            if pos < size - 1 && nsdf[pos] <= 0 {
                if curMaxPos > 0 {
                    maxPositions.append(curMaxPos)
                    curMaxPos = 0
                }
                while pos < size - 1 && nsdf[pos] <= 0 { pos += 1 }
            }
        }
        if curMaxPos > 0 { maxPositions.append(curMaxPos) }
        return maxPositions
    }

    /// Parabolic interpolation around a discrete peak (shared MPM/YIN step).
    static func parabolic(_ nsdf: [Float], _ tau: Int) -> (tau: Double, clarity: Double) {
        guard tau > 0 && tau < nsdf.count - 1 else { return (Double(tau), Double(nsdf[tau])) }
        let s0 = Double(nsdf[tau - 1]), s1 = Double(nsdf[tau]), s2 = Double(nsdf[tau + 1])
        let denom = 2.0 * (2.0 * s1 - s2 - s0)
        let shift = denom != 0 ? (s2 - s0) / denom : 0.0
        return (Double(tau) + shift, s1 + 0.5 * shift * (s2 - s0))
    }

    /// Pitch of one window (samples, mono 16 kHz) — upstream-faithful
    /// acceptance: collect parabolic estimates of peaks whose RAW nsdf > 0.5
    /// (MPM_SMALL_CUTOFF), then take the FIRST estimate whose interpolated
    /// clarity ≥ 0.93 × highest amplitude (MPM_CUTOFF). Returns (hz, clarity);
    /// hz = 0 when no estimate survives (silence) or pitch ≤ the 80 Hz floor.
    public static func pitch(window: ArraySlice<Float>, windowSize: Int) -> (hz: Double, clarity: Double) {
        var nsdfBuf: [Float] = []
        nsdfBuf.reserveCapacity(windowSize / 2)
        computeNSDF(window, window: windowSize, out: &nsdfBuf)
        let peaks = peakPicking(nsdfBuf)
        guard !peaks.isEmpty else { return (0, 0) }

        var highestAmplitude = -Double.greatestFiniteMagnitude
        var estimates: [(tau: Double, clarity: Double)] = []
        for tau in peaks {
            highestAmplitude = max(highestAmplitude, Double(nsdfBuf[tau]))
            if nsdfBuf[tau] > Float(0.5) { // MPM_SMALL_CUTOFF
                let est = parabolic(nsdfBuf, tau)
                highestAmplitude = max(highestAmplitude, est.clarity)
                estimates.append(est)
            }
        }
        guard !estimates.isEmpty else { return (0, 0) }
        let actualCutoff = Double(RibbonSpec.cutoff) * highestAmplitude
        for est in estimates where est.clarity >= actualCutoff {
            let hz = Double(RibbonSpec.sampleRate) / est.tau
            if hz > RibbonSpec.lowerPitchCutoff {
                return (hz, est.clarity)
            }
            return (0, est.clarity) // below the 80 Hz floor (vendored returns -1)
        }
        return (0, highestAmplitude)
    }
}

/// Stateful causal ribbon (EngineAPI.livePitch backing, P-105): feed 16 kHz
/// mono samples in any granularity; emits one `RibbonFrame` per 256-sample
/// hop using only PAST samples (zero lookahead). One instance per thread;
/// `reset()` on interruption.
public final class RibbonEngine: @unchecked Sendable {
    private var history: [Float] = []
    private let window: Int
    private let hop: Int
    /// Sample index of history[0] in the stream (for timestamps).
    private var baseSample = 0
    private(set) var samplesConsumed = 0

    public init(window: Int = RibbonSpec.window, hop: Int = RibbonSpec.hop) {
        precondition(window >= 256 && hop >= 1, "window/hop must be positive")
        self.window = window
        self.hop = hop
    }

    public func reset() {
        history.removeAll(keepingCapacity: true)
        baseSample = 0
        samplesConsumed = 0
    }

    /// Feed samples; returns frames for every completed hop (0–n per call).
    /// Causality: a frame is emitted only once `window` past samples exist.
    public func push(_ samples: [Float]) -> [RibbonFrame] {
        history.append(contentsOf: samples)
        samplesConsumed += samples.count
        var frames: [RibbonFrame] = []
        // Guard the negative-numerator case: Int division truncates toward
        // zero, so (896-1024)/256 = 0 (not -1) — without the guard a partial
        // window would emit one frame and slice past the end (caught red on
        // CI arm64 + Linux in testTimestampsOnContractGridAndCausal).
        let emitCount = history.count >= window ? (history.count - window) / hop + 1 : 0
        if emitCount > 0 {
            for k in 0..<emitCount {
                let start = k * hop
                let slice = history[history.startIndex + start..<history.startIndex + start + window]
                let (hz, clarity) = MPM.pitch(window: slice, windowSize: window)
                let t = Double(baseSample + start + window) / Double(RibbonSpec.sampleRate)
                frames.append(RibbonFrame(t: t, hz: hz, clarity: clarity))
            }
            // Next global frame's window starts at emitCount*hop: drop exactly
            // up to that sample so relative start 0 == the next global frame
            // (keeping one hop short would recompute a shifted duplicate).
            let consumed = emitCount * hop
            history.removeFirst(consumed)
            baseSample += consumed
        }
        return frames
    }
}
