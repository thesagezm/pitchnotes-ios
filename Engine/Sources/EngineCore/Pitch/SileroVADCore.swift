import Foundation

// Silero-vad portable core (P-103, PAUL lane).
//
// Mirrors the upstream streaming semantics (snakers4/silero-vad @ bfdc019,
// MIT — OnnxWrapper): exactly 512-sample chunks at 16 kHz (32 ms), a
// 64-sample context prepended to each chunk, and a recurrent `state`
// [2, 1, 128] fed back from `stateN` every call. The ONNX forward pass sits
// behind `SileroVADInference` (ORT-backed implementation in the PitchORT
// package, Apple-only — same split as SwiftF0).
//
// SEMANTICS: silero is a SPEECH VAD, not an energy VAD — non-speech
// transients (noise bursts, clicks) are correctly classified non-speech
// (real-spike evidence, Tests/Spikes/silero_real.py). The app's mic gate
// (P-104) keys on singing/speech presence, which is exactly the intended use.

/// Silero constants (upstream pinned commit; 16 kHz contract rate).
public enum SileroVADSpec {
    /// Chunk size the model requires: exactly 512 @16 kHz (32 ms).
    public static let chunkSamples = 512
    /// Samples of previous audio prepended to each chunk (upstream context).
    public static let contextSamples = 64
    /// Flat recurrent state size ([2, 1, 128]).
    public static let stateSize = 2 * 1 * 128
    public static let sampleRate = 16_000
}

/// Stateless recurrent forward seam. `input` is `context + chunk`
/// (576 samples @16 kHz); `state` is the flat 256-float recurrent state;
/// implementations must be thread-safe per-call and deterministic.
public protocol SileroVADInference: Sendable {
    func run(input: [Float], state: [Float], sampleRate: Int) throws -> (prob: Float, newState: [Float])
}

/// Streaming speech-VAD wrapper. Accepts arbitrary-size sample pushes
/// (MicChunk is ~10–40 ms = 160–640 samples) and emits one probability per
/// completed internal 512-sample chunk. One stream per thread (stateful).
public final class SileroVADStream: @unchecked Sendable {
    private let inference: any SileroVADInference
    private var state: [Float]
    private var context: [Float]
    private var pending: [Float] = []

    public init(inference: any SileroVADInference) {
        self.inference = inference
        self.state = [Float](repeating: 0, count: SileroVADSpec.stateSize)
        self.context = [Float](repeating: 0, count: SileroVADSpec.contextSamples)
    }

    /// Reset the recurrent state + context (interruption, part change).
    public func reset() {
        state = [Float](repeating: 0, count: SileroVADSpec.stateSize)
        context = [Float](repeating: 0, count: SileroVADSpec.contextSamples)
        pending.removeAll(keepingCapacity: true)
    }

    /// Push mono 16 kHz samples; returns one speech probability per completed
    /// 512-sample chunk (0–n results per push depending on chunk size).
    public func push(_ samples: [Float]) throws -> [Float] {
        pending.append(contentsOf: samples)
        var probs: [Float] = []
        while pending.count >= SileroVADSpec.chunkSamples {
            let chunk = Array(pending[0..<SileroVADSpec.chunkSamples])
            pending.removeFirst(SileroVADSpec.chunkSamples)
            let input = context + chunk
            let (prob, newState) = try inference.run(input: input, state: state, sampleRate: SileroVADSpec.sampleRate)
            guard newState.count == SileroVADSpec.stateSize else {
                throw EngineError.contractViolation(
                    "SileroVAD: state size \(newState.count) != \(SileroVADSpec.stateSize)")
            }
            state = newState
            context = Array(input[(input.count - SileroVADSpec.contextSamples)...])
            probs.append(prob)
        }
        return probs
    }
}

/// Microphone gate policy over VAD probabilities (P-104 consumes; kept in the
/// portable core so the live path is unit-testable without AVFoundation).
/// Hysteresis: opens at `onThreshold`, closes below `offThreshold`, and a
/// close is deferred by `minHangChunks` so note tails / breaths are not cut.
public struct VADGate: Sendable {
    public let onThreshold: Float
    public let offThreshold: Float
    public let minHangChunks: Int

    private(set) var open = false
    private var hangRemaining = 0

    /// Defaults: symmetric ±hysteresis around the model's 0.5 voiced
    /// threshold, ~160 ms hang (5 × 32 ms chunks).
    public init(onThreshold: Float = 0.5, offThreshold: Float = 0.35, minHangChunks: Int = 5) {
        self.onThreshold = onThreshold
        self.offThreshold = offThreshold
        self.minHangChunks = minHangChunks
    }

    /// Feed one chunk probability; returns the gate state AFTER this chunk.
    public mutating func observe(prob: Float) -> Bool {
        if prob >= onThreshold {
            open = true
            hangRemaining = minHangChunks
        } else if prob < offThreshold {
            if hangRemaining > 0 {
                hangRemaining -= 1
            } else {
                open = false
            }
        }
        return open
    }
}
