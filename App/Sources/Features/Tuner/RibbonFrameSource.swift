import Foundation
import EngineCore

// RibbonFrameSource (J-101) — the live-frame seam behind the tuner ribbon.
//
// CONTRACT C-6 zero-UI-change swap: the ribbon consumes contract PitchFrames
// only. M1 drives MockEngine.livePitch (mock singer, scripted 12 s loop); when
// Paul's P-105 lands, a LivePitchEngineRibbonSource wraps `ribbonFrame(_:)` —
// the CAUSAL RIBBON SOURCE (D-17/D-19: vendored MPM/YIN, zero lookahead) — and
// conforms to this same protocol. Views never change; the SwiftF0 176 ms
// lookahead path (gradingSource) is NEVER a live-ribbon source (C-6.0).

/// Live-frame producer for the ribbon. Streams at the engine's cadence; the
/// consumer cancels the iterating task to stop.
protocol RibbonFrameSource: Sendable {
    func frames() -> AsyncStream<PitchFrame>
}

/// M1 source: drives `MockEngine.livePitch` on the 16 ms contract grid against
/// wall-clock capture time. livePitch is an array-index lookup (< 1 ms per
/// EngineCore budget test), so a 62.5 Hz tick sits far inside the < 100 ms
/// live feedback budget (AGENTS §8) and never approaches main-thread cost —
/// frames are produced here, off the main actor, and delivered to the model.
struct MockRibbonFrameSource: RibbonFrameSource {

    private let engine: MockEngine
    private let hopSeconds: Double

    init(engine: MockEngine, hopSeconds: Double = EngineContract.hopSeconds) {
        self.engine = engine
        self.hopSeconds = hopSeconds
    }

    func frames() -> AsyncStream<PitchFrame> {
        AsyncStream { continuation in
            let worker = Task(priority: .userInitiated) {
                let start = Date()
                var nextDeadline = start
                while !Task.isCancelled {
                    let captureTime_s = Date().timeIntervalSince(start)
                    let chunk = MicChunk(samples: [], sampleRate: 16000, captureTime_s: captureTime_s)
                    continuation.yield(engine.livePitch(chunk))
                    nextDeadline = nextDeadline.addingTimeInterval(hopSeconds)
                    let nap = nextDeadline.timeIntervalSinceNow
                    if nap > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(nap * 1_000_000_000))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }
}
