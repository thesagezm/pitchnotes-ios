import Foundation

// SwiftF0 portable core (P-101, PAUL lane).
//
// Swift mirrors the reference implementation semantics of lars76/swift-f0
// (MIT, RESEARCH §4b) — model (lars76/swift-f0 `model.onnx`, MIT) does its own
// framing; this core owns: band validation, batch windowing, silence gating,
// 32 ms sliding loudness, and the streaming emit state machine. The neural
// forward pass sits behind `SwiftF0Inference` so this file stays Foundation-
// only and portable (AGENTS §0); the ONNX Runtime-backed session lives in the
// Apple-only PitchORT package (Engine/PitchORT, wired into the app via
// project.yml — Leto X-task), the spike harness validates the real model from
// Python (Tests/Spikes).
//
// Parity vectors: Tests/EngineCoreTests/SwiftF0ReferenceVectors.swift holds the
// pinned model's outputs for a 220 Hz probe; EngineCoreTests assert this core
// reproduces them numerically.

/// SwiftF0 constants (upstream `core.py`; CONTRACTS C-2.4 hop is 16 ms).
public enum SwiftF0Spec {
    /// Model input sample rate.
    public static let sampleRate = 16_000
    /// Frame hop in samples (256 / 16 kHz = 16 ms contract grid, C-2.4).
    public static let hop = 256
    /// 0.016 s (C-2.4).
    public static let framePeriod = 0.016
    /// F#1 — model/contract band low edge (V11).
    public static let fmin = 46.875
    /// C7 — model/contract band high edge (V11).
    public static let fmax = 2093.75
    /// Log-spaced pitch step ratio (95 steps) — a band narrower than one step
    /// holds no candidate (upstream `_range`).
    public static let binRatio = pow(2093.75 / 46.875, 1.0 / 94.0)
    /// A streamed frame is final once this many LATER frames exist
    /// (10 × 16 ms + own hop = 176 ms lookahead, RESEARCH §4b).
    public static let lookaheadFrames = 10
    /// Earlier frames that reproduce batch results (model receptive field).
    public static let leftFrames = 11
    /// Batch window size in frames (30 s) — bounds inference memory.
    public static let windowFrames = 1875
    /// Frames whose 256-sample hop peaks below this get confidence 0
    /// (digital silence is off-distribution for the model).
    public static let silencePeak: Float = 1e-3
    /// Voiced iff confidence ≥ this (upstream calibration).
    public static let voicedThreshold = 0.5
}

/// Neural forward seam. Implementations must be thread-safe and stateless:
/// the same audio slice always produces the same outputs (determinism, S-rules).
/// `audio` is mono 16 kHz float PCM in [-1, 1]; length = n_frames * 256.
public protocol SwiftF0Inference: Sendable {
    func run(audio: [Float], fmin: Float, fmax: Float) throws -> (pitch: [Double], confidence: [Float])
}

/// fmin/fmax band filter (upstream `_range`): clamped to the model range and
/// rejected when the band cannot hold a pitch candidate. Passed to the model,
/// which restricts its candidates INTO the band (clamps, does not unvoice).
public struct SwiftF0Band: Sendable, Equatable {
    public let fmin: Double
    public let fmax: Double

    public init(fmin: Double? = nil, fmax: Double? = nil) throws {
        let lo = max(SwiftF0Spec.fmin, fmin ?? SwiftF0Spec.fmin)
        let hi = min(SwiftF0Spec.fmax, fmax ?? SwiftF0Spec.fmax)
        guard lo < hi else {
            throw EngineError.contractViolation(
                "SwiftF0 band: require fmin < fmax within \(SwiftF0Spec.fmin)–\(SwiftF0Spec.fmax) Hz, got \(lo)–\(hi)")
        }
        guard hi >= lo * SwiftF0Spec.binRatio else {
            throw EngineError.contractViolation(
                "SwiftF0 band: fmax must be ≥ \(String(format: "%.5f", SwiftF0Spec.binRatio)) × fmin so the band holds a pitch candidate")
        }
        self.fmin = lo
        self.fmax = hi
    }
}

/// Silence gate + loudness (upstream `_run` postprocessing). A trailing frame
/// shorter than one hop (sub-hop flush of a short stream) uses its remaining
/// samples, matching upstream's `audio[None, :]` path.
public enum SwiftF0Postprocessor {
    /// Frames whose hop (or trailing partial hop) peaks below
    /// `SwiftF0Spec.silencePeak` get confidence 0.
    public static func gateConfidence(audio: [Float], frameCount: Int, confidence: [Float]) -> [Float] {
        var out = confidence
        let count = min(frameCount, out.count)
        var i = 0
        while i < count {
            let start = i * SwiftF0Spec.hop
            let length = min(SwiftF0Spec.hop, max(0, audio.count - start))
            var peak: Float = 0
            if length > 0 {
                let hopStart = audio.startIndex + start
                for k in 0..<length {
                    let v = abs(audio[hopStart + k])
                    if v > peak { peak = v }
                }
            }
            if peak < SwiftF0Spec.silencePeak { out[i] = 0.0 }
            i += 1
        }
        return out
    }

    /// 32 ms sliding loudness in dBFS: rms = sqrt((power[i-1] + power[i]) / 512),
    /// 20·log10(max(rms, 1e-7)); frame 0 uses power[-1] = 0 (stream-start
    /// semantics — batch windowing always slices from ≥ leftFrames context
    /// except the very first frames of a stream, matching upstream). A trailing
    /// partial hop contributes its remaining samples.
    public static func loudness(audio: [Float], frameCount: Int) -> [Double] {
        var power = [Double](repeating: 0, count: frameCount)
        var i = 0
        while i < frameCount {
            let start = i * SwiftF0Spec.hop
            let length = min(SwiftF0Spec.hop, max(0, audio.count - start))
            var acc: Double = 0
            if length > 0 {
                let hopStart = audio.startIndex + start
                for k in 0..<length {
                    let v = Double(audio[hopStart + k])
                    acc += v * v
                }
            }
            power[i] = acc
            i += 1
        }
        var out = [Double](repeating: 0, count: frameCount)
        var prev: Double = 0
        for k in 0..<frameCount {
            let rms = ((prev + power[k]) / 512.0).squareRoot()
            out[k] = 20.0 * log10(max(rms, 1e-7))
            prev = power[k]
        }
        return out
    }
}

/// One emitted frame on the contract grid (C-2.4): `t = i * 0.016`,
/// `hz = 0` means UNVOICED (V11), confidence/loudness per upstream.
public struct SwiftF0Frame: Sendable, Equatable {
    public let t: Double
    public let hz: Double
    public let confidence: Double
    public let loudness_db: Double

    /// Contract mapping: a frame is voiced iff the model's confidence ≥
    /// `SwiftF0Spec.voicedThreshold`; otherwise `hz` is 0 (V11 semantics).
    public var contractPitchFrame: PitchFrame {
        let voiced = confidence >= SwiftF0Spec.voicedThreshold && hz > 0
        return PitchFrame(t: t, hz: voiced ? hz : 0.0, confidence: confidence, loudness_db: loudness_db)
    }
}

/// Batch detection (upstream `detect`): whole-signal inference in
/// `windowFrames` windows with `leftFrames` left context and `lookaheadFrames`
/// right context, so windowed results reproduce whole-signal results.
public enum SwiftF0Batch {
    public static func detect(audio: [Float], band: SwiftF0Band, inference: any SwiftF0Inference) throws -> [SwiftF0Frame] {
        let frameCount = max(1, audio.count / SwiftF0Spec.hop)
        var pitchOut: [Double] = []
        var confidenceOut: [Float] = []
        var loudnessOut: [Double] = []
        pitchOut.reserveCapacity(frameCount)
        confidenceOut.reserveCapacity(frameCount)
        loudnessOut.reserveCapacity(frameCount)

        var start = 0
        while start < frameCount {
            let end = min(start + SwiftF0Spec.windowFrames, frameCount)
            let left = max(0, start - SwiftF0Spec.leftFrames)
            let sampleStart = left * SwiftF0Spec.hop
            let sampleEnd: Int
            if end < frameCount {
                sampleEnd = (end + SwiftF0Spec.lookaheadFrames) * SwiftF0Spec.hop
            } else {
                sampleEnd = audio.count
            }
            let window = Array(audio[audio.startIndex + sampleStart..<(audio.startIndex + min(sampleEnd, audio.count))])
            let (pitch, confidence) = try inference.run(
                audio: window,
                fmin: Float(band.fmin),
                fmax: Float(band.fmax))
            let windowFrames = confidence.count
            let gated = SwiftF0Postprocessor.gateConfidence(audio: window, frameCount: windowFrames, confidence: confidence)
            let loudness = SwiftF0Postprocessor.loudness(audio: window, frameCount: windowFrames)
            let lo = start - left
            let hi = min(end - left, windowFrames)
            if lo < hi {
                for k in lo..<hi {
                    pitchOut.append(k < pitch.count ? pitch[k] : 0)
                    confidenceOut.append(gated[k])
                    loudnessOut.append(loudness[k])
                }
            }
            start = end
        }

        return (0..<pitchOut.count).map { i in
            SwiftF0Frame(t: Double(i) * SwiftF0Spec.framePeriod,
                         hz: pitchOut[i],
                         confidence: Double(confidenceOut[i]),
                         loudness_db: loudnessOut[i])
        }
    }
}

/// Streaming detector (upstream `PitchStream`): `push` emits only frames whose
/// `lookaheadFrames` of future context exist (final values); `flush` drains the
/// remainder. 16 kHz mono in (MicChunk contract rate) — upstream-rate audio is
/// resampled by the capture layer (P-104, AVAudioConverter).
///
/// Threading: one stream per thread, mirroring upstream ("a PitchStream must be
/// driven from one thread"). The inference seam must be thread-safe (SwiftF0Inference).
public final class SwiftF0Stream: @unchecked Sendable {
    private let inference: any SwiftF0Inference
    private let band: SwiftF0Band
    private var buffer: [Float] = []
    /// Frame index of `buffer[0]` in the whole stream.
    private var base = 0
    /// Frames emitted so far.
    private(set) var emitted = 0
    private var closed = false

    public init(inference: any SwiftF0Inference, band: SwiftF0Band) {
        self.inference = inference
        self.band = band
    }

    public var isClosed: Bool { closed }

    /// Push 16 kHz mono samples; returns frames that became FINAL (≥ 10 later
    /// frames exist). Empty until the lookahead is satisfied.
    public func push(_ samples: [Float]) throws -> [SwiftF0Frame] {
        guard !closed else {
            throw EngineError.contractViolation("SwiftF0Stream: push after flush")
        }
        buffer.append(contentsOf: samples)
        return try emit(final: false)
    }

    /// Drain all remaining frames; the stream cannot be pushed afterwards.
    public func flush() throws -> [SwiftF0Frame] {
        guard !closed else {
            throw EngineError.contractViolation("SwiftF0Stream: double flush")
        }
        let frames = try emit(final: true)
        closed = true
        return frames
    }

    private func emit(final: Bool) throws -> [SwiftF0Frame] {
        // `first`/`last` index frames relative to the buffer. A stream shorter
        // than one hop still yields one frame at flush (upstream parity).
        let first = emitted - base
        var available = buffer.count / SwiftF0Spec.hop
        if final && base == 0 && available == 0 && !buffer.isEmpty {
            available = 1
        }
        let last = final ? available : available - SwiftF0Spec.lookaheadFrames
        var frames: [SwiftF0Frame] = []
        if last > first {
            let (pitch, confidence) = try inference.run(
                audio: buffer,
                fmin: Float(band.fmin),
                fmax: Float(band.fmax))
            let windowFrames = confidence.count
            let gated = SwiftF0Postprocessor.gateConfidence(audio: buffer, frameCount: windowFrames, confidence: confidence)
            let loudness = SwiftF0Postprocessor.loudness(audio: buffer, frameCount: windowFrames)
            let hi = min(last, windowFrames)
            for k in first..<hi {
                frames.append(SwiftF0Frame(
                    t: Double(emitted + (k - first)) * SwiftF0Spec.framePeriod,
                    hz: k < pitch.count ? pitch[k] : 0,
                    confidence: Double(gated[k]),
                    loudness_db: loudness[k]))
            }
            emitted += hi - first
        } else if !final {
            emitted += 0
        }
        if final {
            buffer.removeAll(keepingCapacity: false)
        } else {
            let keep = max(0, emitted - SwiftF0Spec.leftFrames) - base
            if keep > 0 {
                buffer.removeFirst(keep * SwiftF0Spec.hop)
                base += keep
            }
        }
        return frames
    }
}

/// SwiftF0 pitch engine — the P-101 grading-grade pitch source (D-17.3).
/// Portable orchestration only: band → (resample) → batch/stream → contract
/// frames. The neural seam is injected; ONNX Runtime-backed construction lives
/// in the Apple-only PitchORT package.
///
/// Not an `EngineAPI` conformer yet: `livePitch` (causal, <100 ms) is the
/// ribbon source's job (P-102) and the two sources are fused by the
/// LivePitchEngine facade (P-105, CONTRACTS v0.1).
public struct SwiftF0PitchEngine: Sendable {
    public let inference: any SwiftF0Inference

    public init(inference: any SwiftF0Inference) {
        self.inference = inference
    }

    /// Batch detection of arbitrary-rate mono audio. Rates other than 16 kHz
    /// are resampled with the portable windowed-sinc resampler (device path may
    /// substitute AVAudioConverter upstream of this call, P-104/P-203).
    public func detect(samples: [Float], sampleRate: Int, fmin: Double? = nil, fmax: Double? = nil) throws -> [SwiftF0Frame] {
        let band = try SwiftF0Band(fmin: fmin, fmax: fmax)
        let audio16k: [Float]
        if sampleRate == SwiftF0Spec.sampleRate {
            audio16k = samples
        } else {
            audio16k = AudioResampler.resampleTo16k(samples: samples, sourceRate: sampleRate)
        }
        return try SwiftF0Batch.detect(audio: audio16k, band: band, inference: inference)
    }

    /// Batch detection from a decoded file on disk. Portable formats: PCM16 /
    /// float32 RIFF WAV (fixtures + M2 intermediates); compressed decodes
    /// (MP3/FLAC via AVAudioFile) arrive with the Apple layer (P-203).
    public func detectFile(url: URL, fmin: Double? = nil, fmax: Double? = nil) throws -> [SwiftF0Frame] {
        let wav = try PCMWaveReader.read(url: url)
        return try detect(samples: wav.samples, sampleRate: wav.sampleRate, fmin: fmin, fmax: fmax)
    }

    /// Batch detection returning contract `PitchFrame`s (hz = 0 ⇔ unvoiced).
    public func detectContractFrames(samples: [Float], sampleRate: Int, fmin: Double? = nil, fmax: Double? = nil) throws -> [PitchFrame] {
        try detect(samples: samples, sampleRate: sampleRate, fmin: fmin, fmax: fmax).map { $0.contractPitchFrame }
    }

    /// New streaming detector on the 16 kHz contract rate.
    public func stream(fmin: Double? = nil, fmax: Double? = nil) throws -> SwiftF0Stream {
        SwiftF0Stream(inference: inference, band: try SwiftF0Band(fmin: fmin, fmax: fmax))
    }
}
