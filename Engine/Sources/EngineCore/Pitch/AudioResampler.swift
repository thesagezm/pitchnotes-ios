import Foundation

/// Portable windowed-sinc resampler (P-101). Offline path for
/// `SwiftF0PitchEngine.detect` — arbitrary source rate → the SwiftF0 model's
/// 16 kHz. Kaiser-windowed sinc with the anti-alias cutoff at 90 % of the
/// TARGET Nyquist (the tighter constraint when downsampling); 16 zero
/// crossings per side ≈ −80 dB stopband. Deterministic, allocation-light,
/// no Accelerate/vDSP dependency (AGENTS §0 portability; device paths may
/// swap in AVAudioConverter upstream, P-104/P-203).
public enum AudioResampler {
    /// Zero crossings of the sinc per side (kernel half-width in cycles).
    private static let zeroCrossings = 16.0
    /// Kaiser window shape parameter (β ≈ 8.6 ⇒ ~ −80 dB sidelobes).
    private static let kaiserBeta = 8.6
    /// Anti-alias cutoff as a fraction of the target Nyquist rate.
    private static let cutoffFraction = 0.90

    /// Resample mono `samples` at `sourceRate` to 16 kHz. Identical rates are
    /// still copied through the generic path by callers that need it; the
    /// engine short-circuits at 16 kHz.
    public static func resampleTo16k(samples: [Float], sourceRate: Int) -> [Float] {
        resample(samples: samples, sourceRate: sourceRate, targetRate: SwiftF0Spec.sampleRate)
    }

    public static func resample(samples: [Float], sourceRate: Int, targetRate: Int) -> [Float] {
        precondition(sourceRate > 0 && targetRate > 0, "sample rates must be positive")
        guard !samples.isEmpty else { return [] }
        guard sourceRate != targetRate else { return samples }

        let ratio = Double(targetRate) / Double(sourceRate)
        let outCount = Int(Double(samples.count) * ratio)
        guard outCount > 0 else { return [] }

        // Cutoff in cycles per INPUT sample: min(source, target) Nyquist × 0.9.
        let cutoffHz = cutoffFraction * 0.5 * Double(min(sourceRate, targetRate))
        let fc = cutoffHz / Double(sourceRate)
        // Kernel half-width in input samples.
        let halfWidth = zeroCrossings / max(fc, 1e-9)
        let norm = 1.0 / besselI0(kaiserBeta)

        var out = [Float](repeating: 0, count: outCount)
        let src = samples
        let n = src.count
        for k in 0..<outCount {
            let tau = Double(k) * Double(sourceRate) / Double(targetRate)
            let lo = max(0, Int(ceil(tau - halfWidth)))
            let hi = min(n - 1, Int(floor(tau + halfWidth)))
            var acc: Double = 0
            if lo <= hi {
                for m in lo...hi {
                    let x = tau - Double(m)
                    let u = x / halfWidth
                    if abs(u) >= 1.0 { continue }
                    let window = besselI0(kaiserBeta * (1.0 - u * u).squareRoot()) * norm
                    // Kernel h(x) = 2·fc·sinc(2·fc·x)·window, sinc(y)=sin(πy)/(πy);
                    // equivalently sin(2πfc·x)/(πx) with the x→0 limit 2·fc.
                    let sincArg = 2.0 * .pi * fc * x
                    let kernel: Double
                    if abs(x) < 1e-12 {
                        kernel = 2.0 * fc
                    } else {
                        kernel = sin(sincArg) / (.pi * x)
                    }
                    acc += Double(src[src.startIndex + m]) * kernel * window
                }
            }
            out[k] = Float(acc)
        }
        return out
    }

    /// Modified Bessel function of the first kind, order 0 (series — converges
    /// quickly for the |x| ≤ β range used here).
    static func besselI0(_ x: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        let half = 0.5 * x
        var k = 1.0
        while term > sum * 1e-15 && k < 64 {
            term *= (half / k) * (half / k)
            sum += term
            k += 1
        }
        return sum
    }
}
