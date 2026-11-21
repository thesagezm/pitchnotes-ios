import Foundation

// P-104 · Streaming chunked resampler (portable capture core, PAUL lane).
//
// `AudioResampler` is a stateless WHOLE-BUFFER windowed-sinc resampler (P-101,
// offline path). Feeding it 1024-sample mic chunks directly would truncate the
// kernel at every chunk edge (half-width ≈ 107 input samples @48k→16k — ~10% of
// every chunk computed with a clipped kernel ⇒ periodic ripple into the
// ribbon's NSDF). This wrapper makes it stream-continuous with a carried
// HISTORY TAIL + deferred emission: outputs are emitted only once their full
// kernel support is inside [history + chunk]; the deferred tail is healed by
// the next submit. The device path may substitute AVAudioConverter upstream of
// the ring (ENGINE.md) — this portable path keeps the SIMULATED spike
// equivalent to the device pipeline (Linux-testable, AGENTS §0).
//
// Phase-continuity invariant: output j's read position is
// tau_global(j) = j · sourceRate/targetRate from stream start, and the
// stateless resampler grids tau at the same step — so global alignment holds
// iff combinedStart = consumed − tail.count is a multiple of
// step = sourceRate/gcd(sourceRate, targetRate). We keep
// tail.count ≡ consumed (mod step) with tail.count ≥ halfWidth+1 (heals the
// left edge); no fractional phase accumulator is needed.

/// Stateful chunked resampler: `submit` arbitrary-size chunks, `flush` at
/// stream end, `drain` the emitted output. Same-rate audio passes through.
public final class StreamingResampler: @unchecked Sendable {

    public let sourceRate: Int
    public let targetRate: Int

    /// Kernel half-width in INPUT samples (matches AudioResampler constants).
    private let halfWidth: Double
    /// sourceRate / gcd(sourceRate, targetRate) — the phase-alignment modulus.
    private let step: Int

    private var tail: [Float] = []
    private var consumed = 0   // source samples ingested (global)
    private var emitted = 0    // output samples emitted (global)
    private var atStreamStart = true
    private var outputQueue: [Float] = []  // deferred output, drained FIFO

    public init(sourceRate: Int, targetRate: Int) {
        precondition(sourceRate > 0 && targetRate > 0)
        self.sourceRate = sourceRate
        self.targetRate = targetRate
        guard sourceRate != targetRate else {
            self.halfWidth = 0
            self.step = 1
            return
        }
        let cutoffFraction = 0.90
        let fc = cutoffFraction * 0.5 * Double(min(sourceRate, targetRate)) / Double(sourceRate)
        self.halfWidth = 16.0 / max(fc, 1e-9)
        var a = sourceRate, b = targetRate
        while b != 0 { (a, b) = (b, a % b) }
        self.step = sourceRate / a
    }

    /// True when nothing is buffered (no history, no deferred output).
    public var isEmpty: Bool { outputQueue.isEmpty && tail.isEmpty }

    /// Feed one chunk at the source rate. Output accrues for `drain()`.
    public func submit(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        if sourceRate == targetRate {
            outputQueue.append(contentsOf: samples)
            consumed += samples.count
            emitted += samples.count
            return
        }

        let combined = tail + samples
        let combinedStart = consumed - tail.count // ≡ 0 (mod step) by invariant
        let resampled = AudioResampler.resample(samples: combined,
                                                sourceRate: sourceRate, targetRate: targetRate)
        let ratio = Double(targetRate) / Double(sourceRate)
        let len = combined.count

        // Emittable outputs: tau_local(k) = k·sourceRate/targetRate must keep
        // the full kernel inside `combined` — except at the TRUE stream start,
        // where the left clamp IS the signal edge and emission starts at k = 0.
        let kFirst = atStreamStart ? 0 : max(0, Int(ceil(halfWidth * ratio)))
        let kLast = Int(floor((Double(len) - 1.0 - halfWidth) * ratio))

        // First emittable GLOBAL index must equal `emitted` (the invariant);
        // the skip guard is defensive — never drift silently.
        let jFirst = kFirst + combinedStart / step
        let skip = max(0, emitted - jFirst)
        let lo = kFirst + skip
        if lo <= kLast && kLast < resampled.count {
            outputQueue.append(contentsOf: resampled[lo...kLast])
            emitted += kLast - lo + 1
        }

        consumed += samples.count
        atStreamStart = false
        tail = Self.carriedTail(combined: combined, consumed: consumed, emitted: emitted,
                                tauPerOutput: Double(sourceRate) / Double(targetRate),
                                halfWidth: halfWidth, step: step)
    }

    /// History to carry into the next submit: EXACTLY enough that the first
    /// un-emitted output (j = emitted) keeps full kernel support. Every submit
    /// defers the outputs whose support crosses the chunk's right edge, so the
    /// backlog needs ~2×halfWidth of source history — a mere halfWidth tail
    /// silently SKIPS those outputs (caught red by testPipelineFeedsRibbon:
    /// 43018/48000 samples, tone read 181.8 Hz instead of 440).
    /// Alignment: tail.count ≡ consumed (mod step) keeps combinedStart on the
    /// output grid (stream start carries nothing — the left clamp IS the edge).
    static func carriedTail(combined: [Float], consumed: Int, emitted: Int,
                            tauPerOutput: Double, halfWidth: Double, step: Int) -> [Float] {
        guard step > 1 else { return [] }
        // combinedStart ≤ tau_global(emitted) − halfWidth
        // combinedStart = consumed − tail.count
        // ⇒ tail.count ≥ consumed − floor(emitted·tauPerOutput − halfWidth)
        let needStart = Int((Double(emitted) * tauPerOutput - halfWidth).rounded(.down))
        var len = consumed - needStart
        let r = consumed % step
        if len % step != r { len += (r - len % step + step) % step } // round UP (safe: more support)
        len = min(max(len, 0), combined.count)
        return len > 0 ? Array(combined.suffix(len)) : []
    }

    /// End of stream: emit the deferred tail with the final (clamped) edge.
    public func flush() {
        guard sourceRate != targetRate, !tail.isEmpty else { return }
        let resampled = AudioResampler.resample(samples: tail,
                                                sourceRate: sourceRate, targetRate: targetRate)
        let ratio = Double(targetRate) / Double(sourceRate)
        let kFirst = max(0, Int(ceil(halfWidth * ratio)))
        let combinedStart = consumed - tail.count
        let jFirst = kFirst + combinedStart / step
        let skip = max(0, emitted - jFirst)
        let lo = kFirst + skip
        if lo < resampled.count {
            outputQueue.append(contentsOf: resampled[lo...])
            emitted += resampled.count - lo
        }
        tail.removeAll(keepingCapacity: true)
    }


    /// Drain emitted output (FIFO); `maxSamples` nil = everything.
    public func drain(maxSamples: Int? = nil) -> [Float] {
        if let maxSamples, outputQueue.count > maxSamples {
            let out = Array(outputQueue[0..<maxSamples])
            outputQueue.removeFirst(maxSamples)
            return out
        }
        let out = outputQueue
        outputQueue.removeAll(keepingCapacity: true)
        return out
    }

    /// Interruption/stream reset: drops all state (history + deferred output).
    public func reset() {
        tail.removeAll(keepingCapacity: true)
        outputQueue.removeAll(keepingCapacity: true)
        consumed = 0
        emitted = 0
        atStreamStart = true
    }
}
