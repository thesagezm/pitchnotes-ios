import Foundation

// P-207 · Tuning-reference estimator (D-22, PAUL lane). Estimates the song's
// deviation from A440 equal temperament at IMPORT time; the value lands in
// song.json `tuning_cents` (C-2.1, REQUIRED at v1.0) and consumers OFFSET THE
// REFERENCE (grading J-401, ribbon note-name mapping) — **stored audio is
// NEVER resampled/retuned** (D-22 verbatim; fidelity + artifact avoidance).
// The in-memory engine-side retune is M3 transcription only (P-308).
//
// Estimator family = dettato retune.py (RESEARCH; study-only — reimplemented
// from the ruling text, no code copied): circular mean of refined spectral
// peak deviations from the nearest equal-tempered note.
//
//   1. Fold to mono, resample to 16 kHz (deterministic sinc — AudioResampler;
//      the 16 kHz domain is where the frame source lives).
//   2. Frame source: caller-provided frames ([(hz, clarity, t)]) when available
//      (SwiftF0 via PitchORT on device, P-208 parity harness) — M2 default is
//      the vendored MPM ribbon (model-free, Linux-testable, real detector).
//   3. For voiced frames: refine each reported F0 to the LOCAL SPECTRAL PEAK
//      (Hann-windowed radix-2 FFT + parabolic interpolation on log-magnitude,
//      search window ±35 cents) — refinement removes the detector's grid
//      quantization, giving sub-cent deviations on steady tones.
//   4. Deviations wrap to the semitone circle ([-50, +50)) and combine by
//      CIRCULAR MEAN (correct across the ±50 boundary), weighted equally.
//   5. Gates (D-22 "default 0 when the estimate is weak"): fewer than
//      `minVoicedFrames` refined peaks, circular concentration
//      (resultant length) below `minConcentration`, or |mean| < MIN_CENTS=10
//      → 0. Result clamped to ±50 and rounded to an integer.
//
// Cost: ~1 FFT (4096) per refined frame, capped at `maxRefinedFrames`
// evenly-spaced frames — an import-path (non-live) cost, trivial for songs.

public struct TuningEstimator: Sendable {

    public struct Config: Sendable {
        /// D-22 MIN_CENTS: estimates smaller than this are reported as 0.
        public var minCents: Double = 10.0
        /// Result clamp (C-2.1 tuning_cents range).
        public var clampCents: Double = 50.0
        /// Weak-signal gate: minimum deviation count in the pool.
        public var minRefinedFrames: Int = 25
        /// Weak-signal gate: minimum weighted circular concentration (resultant
        /// length in [0,1]; ~1 = tight cluster, ~0 = uniform scatter).
        public var minConcentration: Double = 0.55
        /// Refinement window (samples at 16 kHz; 4096 = 256 ms, 3.9 Hz bins).
        public var window: Int = 4096
        /// Window hop (window/2 = 128 ms overlap-add coverage).
        public var hop: Int = 2048
        /// Candidate band for spectral maxima (vocal-range fundamentals+harmonics).
        public var bandHz: (low: Double, high: Double) = (65.0, 1050.0)
        /// Peak salience floor (fraction of the window's in-band max magnitude).
        public var salienceFloor: Double = 0.02
        /// Top-K maxima per window.
        public var topKPerWindow: Int = 8
        /// Cap on analyzed windows (evenly spaced across the file).
        public var maxWindows: Int = 512
        /// Frame-source clarity gate (when a frame source is supplied).
        public var minClarity: Double = 0.6

        public init() {}
    }

    /// One frame source entry (decouples the estimator from any detector type;
    /// t is the frame CENTER time in seconds). Frames GATE which windows
    /// contribute (SwiftF0 voiced-mask on device, P-208 parity); an EMPTY
    /// frame list = analyze every window — the M2 import default, because the
    /// vendored MPM mis-tracks polyphonic mixtures (DIAG evidence 2026-11-22:
    /// clarity < 0.6 on 150/153 frames of the +35c committed fixture) while
    /// the SPECTRAL MAXIMA of a varispeed-detuned mixture cluster cleanly at
    /// the detune (detto's estimator family, D-22 verbatim).
    public struct Frame: Sendable {
        public let t: Double
        public let hz: Double
        public let clarity: Double
        public init(t: Double, hz: Double, clarity: Double) {
            self.t = t
            self.hz = hz
            self.clarity = clarity
        }
    }

    public let config: Config

    /// Full estimate + the diagnostics behind it (J-205 UI indicator wants the
    /// raw mean + confidence, not just the gated integer).
    public struct Estimate: Sendable {
        /// Final (gated, clamped, rounded) value for song.json tuning_cents.
        public let cents: Int
        /// Ungated circular mean (for UI/debug).
        public let rawMean: Double
        /// Circular concentration in [0,1] (confidence proxy).
        public let concentration: Double
        /// Refined-peak count behind the mean (0 = weak signal).
        public let refinedCount: Int
    }

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Full estimation from MONO PCM (M2 import default): 16 kHz (deterministic
    /// sinc — AudioResampler) → ALL-WINDOWS spectral harvest → circular mean.
    /// NO frame gate here on purpose — the vendored MPM mis-tracks polyphonic
    /// mixtures (DIAG 2026-11-22: clarity < 0.6 on 150/153 frames of the +35c
    /// committed fixture); the spectral maxima of a varispeed-detuned mixture
    /// cluster at the detune regardless (detto estimator family, D-22 verbatim).
    /// Stereo folding happens at the pipeline layer (channel-mean; tuning is
    /// identical across channels).
    public func estimate(samples: [Float], sampleRate: Int) -> Int {
        let x16 = sampleRate == SwiftF0Spec.sampleRate
            ? samples
            : AudioResampler.resample(samples: samples, sourceRate: sampleRate,
                                      targetRate: SwiftF0Spec.sampleRate)
        return estimateDetailed(samples16k: x16, frames: []).cents
    }

    /// Estimation with an EXTERNAL frame source (SwiftF0 frames on device;
    /// test contours). `samples` must be 16 kHz mono (SwiftF0Spec domain).
    public func estimate(samples16k: [Float], frames: [Frame]) -> Int {
        estimateDetailed(samples16k: samples16k, frames: frames).cents
    }

    /// Full detail path (see Estimate). All gates apply exactly as documented.
    public func estimateDetailed(samples16k: [Float], frames: [Frame]) -> Estimate {
        let cfg = config
        let win = cfg.window
        guard samples16k.count >= win else {
            return Estimate(cents: 0, rawMean: 0, concentration: 0, refinedCount: 0)
        }

        // Window selection: centers at hop spacing. A non-empty frame source
        // GATES windows (≥1 overlapping frame with clarity ≥ minClarity);
        // empty source = every window (M2 default — see Frame doc).
        let usable = samples16k.count - win
        let allCenters = stride(from: 0, through: usable, by: cfg.hop).map { $0 + win / 2 }
        let centers: [Int]
        if frames.isEmpty {
            centers = allCenters
        } else {
            let voiced = frames.filter { $0.clarity >= cfg.minClarity }
            let gate = voiced.map { Int($0.t * Double(SwiftF0Spec.sampleRate)) }
            let picked = allCenters.filter { c in
                gate.contains { abs($0 - c) <= cfg.hop }
            }
            guard !picked.isEmpty else {
                return Estimate(cents: 0, rawMean: 0, concentration: 0, refinedCount: 0)
            }
            centers = picked
        }
        // Cap analyzed windows (evenly spaced).
        let step = max(1, centers.count / cfg.maxWindows)
        let analyzed = stride(from: 0, to: centers.count, by: step).map { centers[$0] }

        // Harvest: per window, top-K in-band spectral maxima → parabolic
        // refine → magnitude-weighted deviation pool.
        var sinSum = 0.0, cosSum = 0.0, weightSum = 0.0
        var devCount = 0
        let binHz = Double(SwiftF0Spec.sampleRate) / Double(win)
        let fft = Radix2FFT(size: win)
        let half = win / 2
        let scale = 2.0 * Double.pi / Double(win - 1)

        for center in analyzed {
            let start = center - half
            guard start >= 0 && start + win <= samples16k.count else { continue }
            var re = [Double](repeating: 0, count: win)
            for i in 0..<win {
                re[i] = Double(samples16k[start + i]) * 0.5 * (1.0 - cos(scale * Double(i)))
            }
            let mag = fft.magnitude(re)

            // In-band salience reference + candidates (local maxima).
            let kLow = max(2, Int(cfg.bandHz.low / binHz))
            let kHigh = min(half - 2, Int(cfg.bandHz.high / binHz))
            guard kLow <= kHigh else { continue }
            var bandMax = 0.0
            for k in kLow...kHigh { bandMax = max(bandMax, mag[k]) }
            let floorMag = bandMax * cfg.salienceFloor
            guard bandMax > 0 else { continue }

            var candidates: [(bin: Int, mag: Double)] = []
            for k in kLow...kHigh where mag[k] > floorMag && mag[k] > mag[k - 1] && mag[k] >= mag[k + 1] {
                candidates.append((k, mag[k]))
            }
            candidates.sort { $0.mag > $1.mag }
            for cand in candidates.prefix(cfg.topKPerWindow) {
                let k = cand.bin
                // Parabolic interpolation on log-magnitude → sub-bin peak.
                let l0 = log(mag[k - 1] + 1e-30), l1 = log(mag[k] + 1e-30), l2 = log(mag[k + 1] + 1e-30)
                let denom = l0 - 2.0 * l1 + l2
                let delta = denom == 0 ? 0.0 : max(-1.0, min(1.0, 0.5 * (l0 - l2) / denom))
                let hz = (Double(k) + delta) * binHz
                guard hz > 0 else { continue }
                // Deviation from the nearest equal-tempered note, wrapped to
                // the semitone circle [-50, +50).
                let cents = 1200.0 * log2(hz / 440.0)
                var dev = cents - 100.0 * (cents / 100.0).rounded()
                if dev >= 50.0 { dev -= 100.0 }
                if dev < -50.0 { dev += 100.0 }
                let w = cand.mag
                let theta = 2.0 * Double.pi * dev / 100.0
                sinSum += w * sin(theta)
                cosSum += w * cos(theta)
                weightSum += w
                devCount += 1
            }
        }

        guard devCount >= cfg.minRefinedFrames, weightSum > 0 else {
            let raw = weightSum > 0
                ? atan2(sinSum / weightSum, cosSum / weightSum) * 100.0 / (2.0 * Double.pi)
                : 0.0
            return Estimate(cents: 0, rawMean: raw, concentration: 0, refinedCount: devCount)
        }
        let mean = atan2(sinSum, cosSum) * 100.0 / (2.0 * Double.pi)
        let concentration = (sinSum * sinSum + cosSum * cosSum).squareRoot() / weightSum
        let gated = concentration >= cfg.minConcentration && abs(mean) >= cfg.minCents
        let clamped = max(-cfg.clampCents, min(cfg.clampCents, mean))
        return Estimate(cents: gated ? Int(clamped.rounded()) : 0,
                        rawMean: mean, concentration: concentration,
                        refinedCount: devCount)
    }

    /// MPM ribbon frame source (vendored, model-free). Public so tests and the
    /// pipeline can reuse the exact frame semantics.
    public func ribbonFrames(_ samples16k: [Float]) -> [Frame] {
        let engine = RibbonEngine()
        return engine.push(samples16k).map { Frame(t: $0.t, hz: $0.hz, clarity: $0.clarity) }
    }

    /// Circular mean over the semitone circle: deviations are angles on a
    /// 100-cent circle; returns (meanDeviation, resultantLength). Handles the
    /// ±50 boundary correctly (a cluster near +49/-49 stays near +49).
    public static func circularMean(_ devs: [Double]) -> (mean: Double, concentration: Double) {
        var sinSum = 0.0, cosSum = 0.0
        for dev in devs {
            let theta = 2.0 * Double.pi * dev / 100.0
            sinSum += sin(theta)
            cosSum += cos(theta)
        }
        let mean = atan2(sinSum, cosSum) * 100.0 / (2.0 * Double.pi)
        let n = Double(max(devs.count, 1))
        let concentration = (sinSum * sinSum + cosSum * cosSum).squareRoot() / n
        return (mean, concentration)
    }

}

/// Iterative radix-2 complex FFT (Cooley–Tukey), deterministic, dependency-free.
/// Real-input convenience: magnitudes of the first N/2 bins.
struct Radix2FFT {
    let size: Int
    private let rev: [Int]
    private let twiddle: [[Double]]  // per-stage cos/sin pairs

    init(size: Int) {
        precondition(size >= 2 && size & (size - 1) == 0, "radix-2 size required")
        self.size = size
        // Bit-reversal permutation table.
        var rev = [Int](repeating: 0, count: size)
        let bits = Int(log2(Double(size)))
        for i in 0..<size {
            var r = 0, v = i
            for _ in 0..<bits {
                r = (r << 1) | (v & 1)
                v >>= 1
            }
            rev[i] = r
        }
        self.rev = rev
        // Twiddles per stage.
        var twiddle: [[Double]] = []
        var m = 2
        while m <= size {
            let half = m / 2
            var stage: [Double] = []
            stage.reserveCapacity(half * 2)
            for k in 0..<half {
                let angle = -2.0 * Double.pi * Double(k) / Double(m)
                stage.append(cos(angle))
                stage.append(sin(angle))
            }
            twiddle.append(stage)
            m <<= 1
        }
        self.twiddle = twiddle
    }

    /// In-place-style transform on a copy; returns magnitudes for bins 0..<size/2.
    func magnitude(_ real: [Double]) -> [Double] {
        var re = [Double](repeating: 0, count: size)
        var im = [Double](repeating: 0, count: size)
        for i in 0..<size {
            re[rev[i]] = real[i]
        }
        var m = 2, stage = 0
        while m <= size {
            let half = m / 2
            let tw = twiddle[stage]
            var base = 0
            while base < size {
                for k in 0..<half {
                    let wr = tw[2 * k], wi = tw[2 * k + 1]
                    let i0 = base + k, i1 = i0 + half
                    let tr = re[i1] * wr - im[i1] * wi
                    let ti = re[i1] * wi + im[i1] * wr
                    re[i1] = re[i0] - tr
                    im[i1] = im[i0] - ti
                    re[i0] += tr
                    im[i0] += ti
                }
                base += m
            }
            m <<= 1
            stage += 1
        }
        var out = [Double](repeating: 0, count: size / 2)
        for k in 0..<size / 2 {
            out[k] = (re[k] * re[k] + im[k] * im[k]).squareRoot()
        }
        return out
    }
}
