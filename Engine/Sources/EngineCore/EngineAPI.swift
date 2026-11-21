import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// C-3 · Engine API (CONTRACTS.md v0.0, RATIFIED 2026-11-20 UTC — L-006).
// Exact signatures per contract. Paul implements (`EngineAPI` + real engines);
// Jess consumes via `MockEngine` from day one (J-002). This file must not import
// UIKit/SwiftUI/AVFoundation/ONNX (portability, AGENTS §0); AVFoundation types
// stay OUT of the protocol signatures — plain value types only.

/// Decoded/normalized 44.1 kHz mix on disk (C-3).
public struct DecodedAudio: Sendable {
    /// Decoded/normalized audio file on disk (44.1 kHz mix).
    public let url: URL
    /// 44100 per D-8.
    public let sampleRate: Int
    public let channels: Int
    public let duration_s: Double

    public init(url: URL, sampleRate: Int, channels: Int, duration_s: Double) {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        self.duration_s = duration_s
    }
}

/// D-9: `twoStem` is default/first (vocals/instrumental).
public enum SeparationMode: String, Sendable { case twoStem, multiStem }

public enum NoteSource: Sendable {
    case stem(URL)
    case mix(URL)
}

/// Mono mic input chunk for the live path (C-3).
public struct MicChunk: Sendable {
    /// Mono, 16 kHz, ~10–40 ms.
    public let samples: [Float]
    /// 16000.
    public let sampleRate: Int
    public let captureTime_s: Double

    public init(samples: [Float], sampleRate: Int, captureTime_s: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.captureTime_s = captureTime_s
    }
}

public enum EngineError: Error, Sendable {
    case importFailed(String)
    case unsupportedFormat(String)
    case separationFailed(String)
    case modelMissing(String)
    case contractViolation(String)
}

/// AsyncSequence of PitchFrame on a 16 ms grid (C-2.4 values). Engine-owned
/// implementation: iteration + cancellation (breaking out of `for await` cancels
/// the producing task via the stream's termination handler).
public struct PitchFrameStream: AsyncSequence, Sendable {
    public typealias Element = PitchFrame

    private let stream: AsyncStream<PitchFrame>

    public init(_ stream: AsyncStream<PitchFrame>) {
        self.stream = stream
    }

    public func makeAsyncIterator() -> AsyncStream<PitchFrame>.Iterator {
        stream.makeAsyncIterator()
    }
}

/// The engine interface (C-3). Threading model (v0.0):
/// - `importAudio/separate/pitchFrames/noteTrack` — `async`; long-running;
///   internally serialized per engine instance; support cooperative cancellation
///   (Task.isCancelled checked between chunks); progress reporting arrives in
///   contract v1.0 (L-203).
/// - `livePitch` — synchronous, thread-safe, no locks held on the audio thread,
///   never blocks on I/O; must return within the <100 ms feedback budget (§8).
/// - All bundled output MUST validate against C-2 schemas (Paul's responsibility;
///   see `BundleValidator`).
public protocol EngineAPI: Sendable {
    func importAudio(url: URL) async throws -> DecodedAudio
    func separate(_ audio: DecodedAudio, mode: SeparationMode) async throws -> [Part: URL]
    func pitchFrames(_ audio: DecodedAudio, fmin: Double, fmax: Double) async throws -> PitchFrameStream
    func noteTrack(_ source: NoteSource, part: Part) async throws -> NoteTrack
    /// Real-time path. Called on the audio/engine queue.
    func livePitch(_ chunk: MicChunk) -> PitchFrame
}

/// Contract constants used across the engine (values from CONTRACTS v0.0 / §8).
public enum EngineContract {
    /// Voiced pitch range (V11): F#1–C7.
    public static let hzMin: Double = 46.9
    public static let hzMax: Double = 2093.75
    /// PitchFrames grid (C-2.4).
    public static let hopMs: Double = 16.0
    public static let hopSeconds: Double = 0.016
    /// Live feedback budget (§8).
    public static let liveFeedbackBudget_ms: Double = 100.0
    /// MIDI reference: A440, C4 = 60 (C-2.3).
    public static func hzForMidi(_ midi: Double) -> Double { 440.0 * pow(2.0, (midi - 69.0) / 12.0) }
    /// Cents offset applied to a base frequency (+ = sharper).
    public static func detune(hz: Double, cents: Double) -> Double { hz * pow(2.0, cents / 1200.0) }
}
