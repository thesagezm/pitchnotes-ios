import XCTest
@testable import EngineCore

// P-104 capture-core tests: the SIMULATED stream spike (AC: no drops over a
// real-shaped session: 1024 @48 kHz producer frames, hop-paced consumer),
// ring overflow drop accounting, reset hooks, streaming-resampler continuity
// (sine through the pipeline stays accurate in the ribbon — no chunk-edge
// ripple), and a concurrent producer/consumer sanity pass.

final class CapturePipelineTests: XCTestCase {

    private func sine(_ hz: Double, seconds: Double, rate: Int, amplitude: Float = 0.5) -> [Float] {
        let n = Int(seconds * Double(rate))
        return (0..<n).map { i -> Float in
            Float(amplitude) * Float(sin(2.0 * .pi * hz * Double(i) / Double(rate)))
        }
    }

    /// The AC spike: 60 s session, producer frames 1024 @48 kHz (21.33 ms),
    /// consumer draining every submit (engine queue keeps up) → zero drops,
    /// exact 16 kHz output rate, all samples accounted for.
    func testSimulatedStreamNoDrops() {
        let pipeline = CapturePipeline(capacitySeconds: 1.0)
        let duration = 60.0
        let tone = sine(220.0, seconds: duration, rate: 48000)
        var drained = 0
        var i = 0
        while i < tone.count {
            let end = min(i + CaptureSpec.frameSamples, tone.count)
            pipeline.submit(Array(tone[i..<end]), sampleRate: 48000,
                            captureTime_s: Double(end) / 48000.0)
            drained += pipeline.drain(maxSamples: Int.max).count
            i = end
        }
        pipeline.finish()
        drained += pipeline.drain(maxSamples: Int.max).count

        let stats = pipeline.snapshot()
        XCTAssertTrue(stats.isClean, "simulated stream must not drop: \(stats)")
        XCTAssertEqual(stats.submits, (tone.count + CaptureSpec.frameSamples - 1) / CaptureSpec.frameSamples)
        // Output rate: 60 s at 16 kHz (±2 rounding across the resampler grid).
        XCTAssertEqual(stats.samplesWritten, Int(duration) * 16000, accuracy: 2)
        XCTAssertEqual(stats.samplesRead, drained)
        XCTAssertEqual(pipeline.pendingCount, 0, "fully drained")
        XCTAssertEqual(stats.samplesWritten, stats.samplesRead + pipeline.pendingCount)
    }

    /// Quality gate: a 440 Hz tone through the 48k→16k pipeline into the
    /// ribbon stays within ±10 cents — the streaming resampler carries the
    /// kernel history so chunk boundaries inject no ripple.
    func testPipelineFeedsRibbonAccurately() {
        let pipeline = CapturePipeline(capacitySeconds: 1.0)
        let tone = sine(440.0, seconds: 3.0, rate: 48000)
        var sixteenK: [Float] = []
        var i = 0
        while i < tone.count {
            let end = min(i + CaptureSpec.frameSamples, tone.count)
            pipeline.submit(Array(tone[i..<end]), sampleRate: 48000)
            sixteenK += pipeline.drain(maxSamples: Int.max)
            i = end
        }
        pipeline.finish()
        sixteenK += pipeline.drain(maxSamples: Int.max)
        XCTAssertGreaterThan(sixteenK.count, 47_000, "3 s ≈ 48000 samples @16 kHz")

        let frames = RibbonEngine().push(sixteenK)
        let mid = frames.dropFirst(12).filter { $0.hz > 0 }
        XCTAssertGreaterThan(mid.count, 150)
        for f in mid {
            let cents = abs(1200.0 * log2(f.hz / 440.0))
            XCTAssertLessThan(cents, 10.0, "440 Hz through pipeline: \(f.hz) Hz (\(cents) c)")
            XCTAssertGreaterThan(f.clarity, 0.9)
        }
    }

    func testRingOverflowCountsDropsAndPreservesFront() {
        // Tiny ring (0.1 s = 1600), NO consumer → overflow must be counted,
        // the retained window must be exactly the ring capacity, and the
        // written+dropped accounting must close over the produced total.
        let pipeline = CapturePipeline(capacitySeconds: 0.1)
        let tone = sine(220.0, seconds: 1.0, rate: 48000)
        var i = 0
        while i < tone.count {
            let end = min(i + CaptureSpec.frameSamples, tone.count)
            pipeline.submit(Array(tone[i..<end]), sampleRate: 48000)
            i = end
        }
        pipeline.finish()
        XCTAssertFalse(pipeline.snapshot().isClean, "no consumer ⇒ drops")
        XCTAssertGreaterThanOrEqual(pipeline.pendingCount, 1600 - 2, "newest-wins ring ends full")
        XCTAssertLessThanOrEqual(pipeline.pendingCount, 1600, "never exceeds capacity")
        // FIFO integrity: the drained window is the MOST RECENT audio — it
        // must match the ideal resampled source's tail slot-for-slot
        // (regression guards: everything-zeros ring indexing, stale window).
        let pendingBefore = pipeline.pendingCount
        let all = pipeline.drain(maxSamples: Int.max)
        XCTAssertEqual(all.count, pendingBefore)
        XCTAssertEqual(pipeline.snapshot().samplesRead, pendingBefore, "read counter tracks the drain")
        let source16k = AudioResampler.resample(samples: tone, sourceRate: 48000, targetRate: 16000)
        XCTAssertEqual(all.count, 1600)
        for k in 0..<all.count {
            XCTAssertEqual(Double(all[k]), Double(source16k[source16k.count - 1600 + k]),
                           accuracy: 1e-3, "ring must retain the newest window, slot \(k)")
        }
    }

    func testResetClearsRingKeepsStatsAndRestartsClean() {
        let pipeline = CapturePipeline(capacitySeconds: 1.0)
        let tone = sine(220.0, seconds: 0.5, rate: 48000)
        pipeline.submit(tone, sampleRate: 48000)
        pipeline.drain(maxSamples: 10)
        XCTAssertGreaterThan(pipeline.pendingCount, 0)

        pipeline.reset() // interruption hook
        XCTAssertEqual(pipeline.pendingCount, 0, "reset empties the ring")
        var stats = pipeline.snapshot()
        XCTAssertEqual(stats.samplesReceived, tone.count, "stats survive reset")
        XCTAssertEqual(stats.samplesRead, 10)

        // Next submit starts a clean stream (no stale resampler tail).
        pipeline.submit(tone, sampleRate: 48000)
        pipeline.finish()
        let out = pipeline.drain(maxSamples: Int.max)
        stats = pipeline.snapshot()
        XCTAssertEqual(out.count, 8000, accuracy: 2, "fresh 0.5 s stream after reset")
        XCTAssertTrue(stats.isClean)
    }

    func testSameRatePassthroughIsExact() {
        let pipeline = CapturePipeline(capacitySeconds: 1.0, sourceSampleRate: 16000)
        let tone = sine(220.0, seconds: 1.0, rate: 16000)
        pipeline.submit(tone, sampleRate: 16000)
        let out = pipeline.drain(maxSamples: Int.max)
        XCTAssertEqual(out.count, 16000)
        XCTAssertEqual(out, tone, "16 kHz in ⇒ byte-identical passthrough")
        XCTAssertTrue(pipeline.snapshot().isClean)
    }

    /// Boxed flag (Swift 6 concurrency-safe sharing across the producer thread).
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        func isSet() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testConcurrentProducerConsumerNoCorruption() {
        let pipeline = CapturePipeline(capacitySeconds: 1.0)
        let tone = sine(220.0, seconds: 4.0, rate: 48000)
        let chunks = stride(from: 0, to: tone.count, by: CaptureSpec.frameSamples).map {
            Array(tone[$0..<min($0 + CaptureSpec.frameSamples, tone.count)])
        }
        let done = Flag()
        // Producer paced like the real mic: one 1024-frame (21.3 ms) chunk per
        // frame period — realtime, so the consumer contract is honest.
        let producer = Thread {
            for c in chunks {
                pipeline.submit(c, sampleRate: 48000)
                Thread.sleep(forTimeInterval: 21.333 / 1000.0)
            }
            pipeline.finish()
            done.set()
        }
        producer.name = "producer"
        producer.start()
        // Consumer (engine-queue stand-in): drains everything each wake,
        // sleeping only when starved — cannot fall behind realtime.
        var read = 0
        while true {
            read += pipeline.drain(maxSamples: Int.max).count
            if done.isSet() { break }
            if pipeline.pendingCount == 0 { Thread.sleep(forTimeInterval: 0.002) }
        }
        while pipeline.pendingCount > 0 {
            read += pipeline.drain(maxSamples: Int.max).count
        }
        let stats = pipeline.snapshot()
        XCTAssertTrue(stats.isClean, "realtime-paced producer + eager consumer ⇒ no drops: \(stats)")
        XCTAssertEqual(stats.samplesRead, read)
        XCTAssertEqual(stats.samplesWritten, stats.samplesRead + pipeline.pendingCount)
        // Rate: 4 s ⇒ 64000 @16 kHz (±2 rounding).
        XCTAssertEqual(stats.samplesWritten, 64_000, accuracy: 2)
    }
}
