import Foundation
import EngineCore

// LivePitchEngineRibbonSource (J-105) — the P-105 facade behind the J-101
// RibbonFrameSource seam. THE C-6.0 SWAP, EXECUTED: the ribbon now consumes
// `LivePitchEngine.ribbonFrame(_:)` — the CAUSAL RIBBON SOURCE (engine_id
// RIBBON_MPM_YIN, lookahead_ms 0, D-17/D-19 vendored MPM/YIN via the Swift
// RibbonEngine). The SwiftF0 gradingSource (176 ms lookahead) is NEVER a
// live-ribbon source (C-6.0) — it is grading-only, post-hoc, M2/M4.
//
// Zero view changes (C-6 contract): RibbonModel/TunerRibbonView still consume
// the same `RibbonFrameSource` protocol and contract PitchFrames; identity is
// READ OFF THE FRAMES (engine_id/lookahead_ms — C-6.0 discipline, v0.1 fields).
//
// Mic chunks flow through MicChunkProviding (below). The capture TAP itself is
// Paul's MicCapture package (P-104), wired into the app target by Leto's
// X-008b/X-011a re-wiring (X-013 seam fixes landed + merged; jess→main 7c98a41).
// The adapter here is written against MicCaptureEngine's documented API behind
// #if canImport + a conditional `import MicCapture` (added at the jess→main
// integration — canImport alone does not bring the type into scope), so real
// mic capture activates with ZERO further code changes (its doc states the
// intended body: "facade.ribbonFrame(chunk)"). Without the package in a target,
// the real ribbon runs on hop-aligned silence chunks — real DSP cost and RTF,
// honest unvoiced output (hz 0).

/// Push-style 16 kHz MicChunk producer (hop-aligned). `start` installs the
/// handler and begins producing; `stop` must be idempotent and thread-safe.
/// Implementations deliver on a NON-main queue (audio-path rules, AGENTS §8).
protocol MicChunkProviding: AnyObject, Sendable {
    func start(into handler: @escaping @Sendable (MicChunk) -> Void) throws
    func stop()
}

/// Placeholder producer until Leto's X-011a re-wiring lands MicCapture in the
/// app target: hop-aligned 256-sample silence chunks @ 16 kHz on the C-2.4
/// grid. Feeds the REAL ribbon engine (NSDF over real windows — the RTF a
/// human reads on the debug screen is the real ribbon cost, not a mock).
final class SilenceMicChunkSource: MicChunkProviding, @unchecked Sendable {

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var handler: (@Sendable (MicChunk) -> Void)?

    func start(into handler: @escaping @Sendable (MicChunk) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        self.handler = handler
        let hop = Int(RibbonSpec.hop) // 256 samples = 16 ms @ 16 kHz
        let hopSeconds = EngineContract.hopSeconds
        task = Task(priority: .userInitiated) {
            let start = Date()
            var nextDeadline = start
            let silence = [Float](repeating: 0, count: hop)
            while !Task.isCancelled {
                let captureTime_s = Date().timeIntervalSince(start)
                handler(MicChunk(samples: silence, sampleRate: RibbonSpec.sampleRate,
                                 captureTime_s: captureTime_s))
                nextDeadline = nextDeadline.addingTimeInterval(hopSeconds)
                let nap = nextDeadline.timeIntervalSinceNow
                if nap > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(nap * 1_000_000_000))
                }
            }
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        task?.cancel()
        task = nil
        handler = nil
    }
}

#if canImport(MicCapture)
import MicCapture
/// Real capture (P-104) the moment MicCapture joins the app target (X-011a):
/// AVAudioEngine tap → 48 kHz→16 kHz conversion → CapturePipeline → hop-aligned
/// MicChunks on the engine's callback queue. Config mirrors MicCaptureEngine's
/// defaults; voiceProcessing OFF for headphone fidelity (J-102 owns the
/// speaker-route flip policy — AudioSessionController, later task).
final class MicCaptureChunkSource: MicChunkProviding, @unchecked Sendable {

    private let engine: MicCaptureEngine
    /// Fired when the capture pipeline resets itself (call/route failure) —
    /// the UI hook for the J-102 interruption banner.
    var onInterruption: (@Sendable () -> Void)?

    init(config: MicCaptureEngine.Config = .init()) {
        self.engine = MicCaptureEngine(config: config)
    }

    func start(into handler: @escaping @Sendable (MicChunk) -> Void) throws {
        engine.onChunk = handler
        engine.onInterruption = { [weak self] in self?.onInterruption?() }
        try engine.start()
    }

    func stop() {
        engine.stop()
    }
}
#endif

/// Honest stand-in for the SwiftF0 neural seam until PitchORT wires the real
/// ORT inference (X-008, Paul): returns per-frame zeros — real SHAPE (the
/// SwiftF0 core's contract: pitch + confidence arrays, one entry per 256-sample
/// frame), zero confidence = unvoiced everywhere. The grading path is NOT a
/// live path (C-6.0) and the facade never calls this on the ribbon path; it
/// exists only so `LivePitchFacade` can be constructed without ORT.
struct PlaceholderSwiftF0Inference: SwiftF0Inference {
    func run(audio: [Float], fmin: Float, fmax: Float) throws -> (pitch: [Double], confidence: [Float]) {
        let frames = audio.count / 256
        return (pitch: [Double](repeating: 0, count: frames),
                confidence: [Float](repeating: 0, count: frames))
    }
}

/// C-6.0 live source: one `LivePitchEngine`, chunks in, `ribbonFrame(_:)` out.
/// Frames carry the engine's own identity (engine_id RIBBON_MPM_YIN,
/// lookahead_ms 0) — nothing here rewrites contract fields.
struct LivePitchEngineRibbonSource: RibbonFrameSource {

    private let engine: any LivePitchEngine & Sendable
    private let mic: any MicChunkProviding

    /// - Parameters:
    ///   - engine: the live facade (P-105). `reset()` is the caller's job on
    ///     interruption (RibbonModel owns lifecycle).
    ///   - mic: chunk producer — MicCaptureChunkSource when the package is
    ///     wired, SilenceMicChunkSource until then (see type docs).
    init(engine: any LivePitchEngine & Sendable, mic: any MicChunkProviding) {
        self.engine = engine
        self.mic = mic
    }

    func frames() -> AsyncStream<PitchFrame> {
        AsyncStream { continuation in
            do {
                try mic.start(into: { chunk in
                    // Causal path ONLY (C-6.0). Runs off-main (mic callback
                    // queue / producer task); the facade is internally locked.
                    continuation.yield(engine.ribbonFrame(chunk))
                })
            } catch {
                // Mic unavailable (permission, routing, X-011a pending) — end
                // the stream; the UI falls back to unvoiced. Honest, no fake
                // frames: RibbonModel shows the designed no-signal state.
                continuation.finish()
                return
            }
            continuation.onTermination = { _ in
                mic.stop()
            }
        }
    }
}

/// Builds the best available chunk producer for this build target.
enum MicChunkSourceFactory {
    /// `true` when the real capture package is in the target (X-011a landed).
    static var hasRealCapture: Bool {
        #if canImport(MicCapture)
        return true
        #else
        return false
        #endif
    }

    static func make() -> any MicChunkProviding {
        #if canImport(MicCapture)
        return MicCaptureChunkSource()
        #else
        return SilenceMicChunkSource()
        #endif
    }
}
