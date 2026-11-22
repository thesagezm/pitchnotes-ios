import XCTest
@testable import MicCapture
import EngineCore

// MicCapture smoke tests (X-011b, PAUL lane — macOS CI only; the package is
// Apple-only, so Linux never builds it). NO mic, NO capture started: these
// cover the platform-neutral surface Leto's gate step runs without hardware —
// (1) config math: defaults + ring wiring match CaptureSpec, and (2) the
// interruption-hook state machine: reset()/stop() semantics through the
// wrapper's public pipeline, exactly what the iOS session observers call.
// The AVAudioEngine tap, audio-session category, and NotificationCenter
// observers are device-only (J-403 loopback + device demo).

final class MicCaptureSmokeTests: XCTestCase {

    // MARK: - (1) Config math (X-011 spec)

    func testConfigDefaultsMatchCaptureSpec() {
        let config = MicCaptureEngine.Config()
        XCTAssertEqual(config.sourceSampleRate, CaptureSpec.sourceSampleRate)
        XCTAssertEqual(config.frameSamples, CaptureSpec.frameSamples)
        XCTAssertEqual(config.sourceSampleRate, 48_000, "device-native default")
        XCTAssertEqual(config.frameSamples, 1_024, "1024 @48k = 21.33 ms tap")
        XCTAssertFalse(config.usesVoiceProcessing, "OFF by default (headphone fidelity; UI flips ON for speaker)")
        XCTAssertEqual(CaptureSpec.targetSampleRate, 16_000, "contract C-3 rate")
    }

    func testRingWiringMatchesRequestedCapacity() {
        // 1.0 s default and a custom 0.5 s both land in the ring as 16 kHz
        // samples — the wrapper must pass `ringCapacitySeconds` through
        // unmangled (seconds × target rate).
        XCTAssertEqual(MicCaptureEngine().pipeline.ring.capacity, 16_000)
        let half = MicCaptureEngine(config: .init(ringCapacitySeconds: 0.5))
        XCTAssertEqual(half.pipeline.ring.capacity, 8_000)
        XCTAssertEqual(half.pipeline.sourceSampleRate, CaptureSpec.sourceSampleRate,
                       "pipeline built with the wrapper's declared source rate")
        XCTAssertEqual(half.pipeline.targetSampleRate, CaptureSpec.targetSampleRate)
    }

    func testPipelineRoundTripThroughWrapperWiring() {
        // Drive the pipeline the engine built (16 kHz path — exact, 1:1):
        let engine = MicCaptureEngine()
        let stats = engine.pipeline.submit([Float](repeating: 0.25, count: 1_600),
                                           sampleRate: 16_000, captureTime_s: 1.0)
        XCTAssertEqual(stats.samplesReceived, 1_600)
        XCTAssertEqual(stats.samplesWritten, 1_600)
        XCTAssertTrue(stats.isClean)
        XCTAssertEqual(engine.pipeline.drain(maxSamples: Int.max).count, 1_600)
        XCTAssertEqual(engine.pipeline.snapshot().samplesRead, 1_600)
        XCTAssertEqual(engine.pipeline.pendingCount, 0)
    }

    func testResampledSubmitUsesDeclaredSourceRate() {
        // Omitting `sampleRate` must fall back to the pipeline's declared
        // 48 kHz source (the tap submits this way): 1024 @48k ≈ 341 @16k
        // (stateful resampler — tolerance for kernel-edge rounding; exact
        // continuity is EngineCore-tested).
        let engine = MicCaptureEngine()
        let stats = engine.pipeline.submit([Float](repeating: 0.1, count: 1_024))
        XCTAssertEqual(stats.samplesReceived, 1_024)
        let drained = engine.pipeline.drain(maxSamples: Int.max)
        engine.pipeline.finish()
        let total = drained.count + engine.pipeline.drain(maxSamples: Int.max).count
        XCTAssertTrue((330...352).contains(total),
                      "1024 @48 kHz → ~341 @16 kHz after finish flush, got \(total)")
    }

    // MARK: - (2) Interruption-hook state machine (X-011 spec)

    func testStopBeforeStartIsNoOpAndStatsSurvive() {
        // stop() guards on isRunning — calling it before start() (or twice)
        // must not touch the pipeline (finish() never runs) and must not
        // crash. Device interruptions rely on this being idempotent.
        let engine = MicCaptureEngine()
        XCTAssertFalse(engine.isRunning)
        engine.pipeline.submit([Float](repeating: 0.5, count: 160), sampleRate: 16_000)
        let before = engine.pipeline.snapshot()
        engine.stop()
        engine.stop()
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(engine.pipeline.snapshot(), before)
        XCTAssertEqual(engine.pipeline.pendingCount, 160)
    }

    func testResetHookEmptiesStreamButKeepsDropHistory() {
        // The route-change / media-services-reset observers call
        // pipeline.reset() (default args). Contract: buffered audio GONE,
        // drop HISTORY survives unless clearStats — an interruption must not
        // silently erase accounting.
        let engine = MicCaptureEngine()
        engine.pipeline.submit([Float](repeating: 0.5, count: 320), sampleRate: 16_000)
        XCTAssertGreaterThan(engine.pipeline.pendingCount, 0)

        engine.pipeline.reset()
        XCTAssertEqual(engine.pipeline.pendingCount, 0, "interruption empties the stream")
        XCTAssertEqual(engine.pipeline.snapshot().samplesReceived, 320, "stats survive reset()")
        XCTAssertTrue(engine.pipeline.snapshot().isClean, "clean history intact")

        engine.pipeline.reset(clearStats: true)
        XCTAssertEqual(engine.pipeline.snapshot(), CaptureStats(), "explicit clearStats wipes")
    }

    func testCallbackQueueDeliversAndChunkCallbacksAreNilSafe() throws {
        // onChunk/onInterruption are optional and unset here; the engine must
        // be constructible and its dedicated serial callbackQueue functional
        // (device delivery path uses it for every hop).
        let engine = MicCaptureEngine()
        XCTAssertNil(engine.onChunk)
        XCTAssertNil(engine.onInterruption)
        let probe = expectation(description: "callbackQueue delivers")
        engine.callbackQueue.async { probe.fulfill() }
        wait(for: [probe], timeout: 5.0)
    }
}
