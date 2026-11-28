import Foundation
import EngineCore
import PitchLogic

// SessionFrameProducer (J-402) — the live-frame seam between the session and
// whatever produces its PitchFrames.
//
// THE CLOCK CONTRACT (the J-402 session clock): a producer stamps frames on
// the SESSION-LOCAL grid — t = seconds since `start`, advancing ONLY while
// the session is un-paused. The reference begins at t = countIn_s; the
// model translates frames to reference-aligned time at ingest (one place).
// Pause is part of the contract because the REFERENCE playback freezes on
// pause (P-402's transport) — a producer that kept stamping through a pause
// would desync the stream from the transport it grades against.
//
// TWO IMPLEMENTATIONS TODAY:
//   · DemoSessionFrameProducer — DemoSinger's synthetic stream dripped on
//     the hop grid (the demo path; labelled DEMO at every UI surface).
//   · RibbonSessionFrameProducer — the REAL mic path: MicCapture/silence
//     chunks → LivePitchFacade.ribbonFrame (C-6.0 causal source, engine_id
//     RIBBON_MPM_YIN). The live ribbon feeds the markers; GRADING-grade
//     frames come from P-401's aligned SwiftF0 batch — when it lands, its
//     producer conforms HERE (one type, zero model/UI change; the same swap
//     the J-105 ribbon precedent made).

protocol SessionFrameProducing: AnyObject {
    /// Begins the stream. `t` starts at 0. Throws when the source cannot
    /// produce at all (no mic / permission denied) — the session surfaces
    /// the honest error and runs frame-less.
    func start(into handler: @escaping @Sendable (PitchFrame) -> Void) throws
    /// Freeze the clock (the transport paused): stop producing; `t` holds.
    func pause()
    /// Continue the SAME stream (t resumes where it paused — no reset).
    func resume()
    /// Rewind the stream to session-local time `toT_s` (the [Restart phrase]
    /// rewind — the transport seeks back and the stream follows it).
    func seek(toT_s: Double)
    /// End the stream for good (done / discarded / retry rebuilds).
    func stop()
}

// MARK: - The demo path (synthetic, labelled)

/// Drips DemoSinger's pre-rendered performance on the 16 ms hop grid.
/// Pause stops the drip; resume continues the SAME stream (the stamps are
/// pre-rendered, so a pause/resume pair is invisible to the clock).
final class DemoSessionFrameProducer: SessionFrameProducing, @unchecked Sendable {

    private let lock = NSLock()
    private var frames: [PitchFrame]
    private var nextIndex = 0
    private var running = false
    private var task: Task<Void, Never>?
    private var handler: (@Sendable (PitchFrame) -> Void)?

    /// - Parameter frames: DemoSinger's session-local stream (the model
    ///   renders it at start — the composed reference is already resolved).
    init(frames: [PitchFrame]) {
        self.frames = frames
    }

    func start(into handler: @escaping @Sendable (PitchFrame) -> Void) throws {
        lock.lock()
        guard !running else { lock.unlock(); return }
        nextIndex = 0
        running = true
        self.handler = handler
        lock.unlock()
        spawnDrip()
    }

    func pause() {
        lock.lock(); running = false; lock.unlock()
    }

    func resume() {
        lock.lock(); running = true; lock.unlock()
    }

    func seek(toT_s: Double) {
        // The stream is pre-rendered: a seek is a drip-index jump. Round UP
        // onto the hop grid so no frame lands before the target.
        let index = Int((toT_s / SessionGrader.hop_s).rounded(.up))
        lock.lock()
        nextIndex = min(max(index, 0), frames.count)
        lock.unlock()
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
        task?.cancel()
        task = nil
        handler = nil
    }

    private func spawnDrip() {
        task?.cancel()
        task = Task(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                var emitted: (frame: PitchFrame, handler: @Sendable (PitchFrame) -> Void)?
                self.lock.lock()
                if self.running, self.nextIndex < self.frames.count,
                   let handler = self.handler {
                    emitted = (self.frames[self.nextIndex], handler)
                    self.nextIndex += 1
                }
                let over = self.nextIndex >= self.frames.count
                self.lock.unlock()
                if let ready = emitted { ready.handler(ready.frame) }
                if over { return }
                try? await Task.sleep(nanoseconds: UInt64(SessionGrader.hop_s * 1_000_000_000))
            }
        }
    }
}

// MARK: - The real path (C-6.0 causal ribbon)

/// Real mic chunks → the LivePitchFacade's ribbon source. The session clock
/// is the HOP INDEX (one hop = one 16 ms step): chunks arrive hop-aligned
/// (CapturePipeline's guarantee), so counting hops IS the transport clock —
/// and pause (chunks stop) freezes it exactly like P-402's playback will.
/// The ribbon's own internal grid t is REPLACED by the session stamp; the
/// frame's identity fields (engine_id RIBBON_MPM_YIN, lookahead_ms 0) pass
/// through untouched (C-6.0 discipline — identity is read off the frames).
final class RibbonSessionFrameProducer: SessionFrameProducing, @unchecked Sendable {

    private let mic: any MicChunkProviding
    private let facade: LivePitchFacade
    private let lock = NSLock()
    private var hopIndex = 0
    private var started = false
    private var handler: (@Sendable (PitchFrame) -> Void)?

    init(mic: (any MicChunkProviding)? = nil) {
        self.mic = mic ?? MicChunkSourceFactory.make()
        // The grading seam is NOT live yet (X-008 wires the real ORT SwiftF0);
        // the placeholder answers unvoiced everywhere — the ribbon path never
        // calls it (C-6.0: the grading source is not a live source).
        self.facade = LivePitchFacade(swiftf0Inference: PlaceholderSwiftF0Inference())
    }

    func start(into handler: @escaping @Sendable (PitchFrame) -> Void) throws {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        hopIndex = 0
        self.handler = handler
        lock.unlock()
        facade.reset()
        try installChunkPipeline(into: handler)
    }

    /// The chunk → ribbon → frame chain (one closure shape for start AND
    /// resume — resume must re-install the CHUNK pipeline, not hand the
    /// frame handler to the chunk source).
    private func installChunkPipeline(into handler: @escaping @Sendable (PitchFrame) -> Void) throws {
        let hopSeconds = EngineContract.hopSeconds
        try mic.start(into: { [weak self] chunk in
            guard let self else { return }
            self.lock.lock()
            var f = self.facade.ribbonFrame(chunk)
            f.t = Double(self.hopIndex) * hopSeconds
            self.hopIndex += 1
            self.lock.unlock()
            handler(f)
        })
    }

    func pause() { mic.stop() }

    func resume() {
        lock.lock()
        let handler = started ? self.handler : nil
        lock.unlock()
        guard let handler else { return }
        // The SAME stream continues: hopIndex holds, the facade keeps its
        // context (a reset here would re-zero the ribbon's filters mid-song).
        try? installChunkPipeline(into: handler)
    }

    func seek(toT_s: Double) {
        // The hop counter jumps (round UP onto the grid, like the demo's
        // seek); the ribbon's accumulated context is stale for the new
        // position — a reset is the documented interruption semantics.
        let hopSeconds = EngineContract.hopSeconds
        let index = Int((toT_s / hopSeconds).rounded(.up))
        lock.lock()
        hopIndex = max(index, 0)
        lock.unlock()
        facade.reset()
    }

    func stop() {
        mic.stop()
        lock.lock()
        started = false
        handler = nil
        lock.unlock()
        facade.reset()
    }
}
