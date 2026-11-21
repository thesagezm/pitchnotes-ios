import Foundation

// P-104 · Portable mic-capture core (PAUL lane): 16 kHz ring buffer +
// audio-thread→engine-queue handoff contract + drop accounting + interruption
// reset hooks. Linux-testable — the SIMULATED stream spike (no drops) runs
// here; the real mic arrives via the Apple-only Engine/MicCapture package
// (AVAudioEngine tap + AVAudioConverter, wired by Leto X-011).
//
// Handoff contract (the whole point of this file):
// - PRODUCER (audio callback queue): `submit` — never blocks, never allocates
//   beyond the resampler's output array; when the consumer is slow the ring
//   OVERFLOWS and the excess is COUNTED as dropped samples (the honest
//   alternative to blocking a realtime thread). Lock-guarded critical sections
//   are memcpy-bounded (< 0.1 ms at contract chunk sizes).
// - CONSUMER (engine queue): `drain` — pulls whatever accumulated (typically
//   one 16 ms hop), feeds RibbonEngine/LivePitchFacade.
// - INTERRUPTIONS: `reset()` empties the ring + resampler state (call from the
//   session-interruption/route-change observers; Apple wrapper owns the
//   notifications). Stats survive unless explicitly cleared.
//
// Budget context (§8 <100 ms feedback): 1024 @48 kHz = 21.3 ms capture frame;
// resample ≪ 1 ms; ring copy < 0.1 ms; drain waits ≤ 1 hop (16 ms); ribbon
// window 64 ms of PAST audio (warm-up only) + ~4 ms/frame compute (measured,
// BENCHMARKS.md). Steady-state ≈ 40 ms typical — measured end-to-end loopback
// is the J-403 device hook.

/// Capture constants (P-104 design point; §8 latency budget).
public enum CaptureSpec {
    /// Source rate delivered by the Apple capture layer (device native in/48k).
    public static let sourceSampleRate = 48_000
    /// AVAudioEngine input tap frame size: 1024 @48 kHz = 21.33 ms.
    public static let frameSamples = 1_024
    /// Contract rate for the whole live path (C-3 MicChunk).
    public static let targetSampleRate = 16_000
}

/// Cumulative counters for one capture session. All sample counts in their
/// stated domain — `samplesReceived` at the SOURCE rate, the rest at 16 kHz.
public struct CaptureStats: Sendable, Equatable {
    public var submits = 0
    public var samplesReceived = 0      // source-rate samples handed to submit
    public var samplesWritten = 0       // 16 kHz samples that entered the ring
    public var samplesDropped = 0       // 16 kHz samples lost to ring overflow
    public var samplesRead = 0          // 16 kHz samples the consumer drained
    public var drops = 0                // number of overflow events
    public var lastDropSamples = 0      // size of the most recent overflow

    public init() {}

    /// The simulated-stream spike AC: zero drops over a session.
    public var isClean: Bool { samplesDropped == 0 }
}

/// Fixed-capacity FIFO of `Float` samples (lock-guarded ring) with
/// LIVE-STREAM semantics: when full, incoming samples OVERWRITE THE OLDEST
/// content (newest-wins sliding window). Rationale: this ring feeds the live
/// ribbon — after a consumer stall the singer needs the NEWEST audio (stale
/// feedback is worse than a counted drop), and overwrite-oldest keeps the
/// retained stream CONTIGUOUS (no gap discontinuities into the NSDF).
public final class MicRingBuffer: @unchecked Sendable {

    public let capacity: Int
    private let lock = NSLock()
    private var storage: [Float]
    private var readPos = 0
    private var count = 0

    public init(capacitySamples: Int) {
        precondition(capacitySamples > 0, "ring capacity must be positive")
        self.capacity = capacitySamples
        self.storage = [Float](repeating: 0, count: capacitySamples)
    }

    public var availableCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    public var freeCount: Int { capacity - availableCount }

    /// Writes `samples`; returns (written, overwritten) — everything lands in
    /// the ring except what slid out as oldest (`overwritten` = caller's drop
    /// count). Never blocks, never grows.
    public func write(_ samples: [Float]) -> (written: Int, overwritten: Int) {
        guard !samples.isEmpty else { return (0, 0) }
        lock.lock(); defer { lock.unlock() }
        var overwritten = 0
        if samples.count >= capacity {
            // Keep only the newest `capacity` samples.
            overwritten = count + samples.count - capacity
            let keep = samples.suffix(capacity)
            for (i, s) in keep.enumerated() { storage[i] = s }
            readPos = 0
            count = capacity
        } else {
            let start = (readPos + count) % capacity
            for (i, s) in samples.enumerated() {
                storage[(start + i) % capacity] = s
            }
            let newCount = min(count + samples.count, capacity)
            overwritten = count + samples.count - newCount
            // The oldest `overwritten` samples slid out: advance readPos.
            readPos = (readPos + overwritten) % capacity
            count = newCount
        }
        return (samples.count, overwritten)
    }

    /// Reads up to `maxSamples` (FIFO). Empty array when drained.
    public func read(maxSamples: Int) -> [Float] {
        guard maxSamples > 0 else { return [] }
        lock.lock(); defer { lock.unlock() }
        let n = min(maxSamples, count)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = storage[(readPos + i) % capacity]
        }
        readPos = (readPos + n) % capacity
        count -= n
        return out
    }

    /// Discards buffered content (interruption hook).
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        readPos = 0
        count = 0
    }
}

/// The capture handoff: producer `submit` (audio queue) → 16 kHz ring →
/// consumer `drain` (engine queue). Owns the streaming resampler and stats.
public final class CapturePipeline: @unchecked Sendable {

    public let sourceSampleRate: Int
    public let targetSampleRate: Int
    public let ring: MicRingBuffer

    private let lock = NSLock()
    private var resampler: StreamingResampler?
    private var stats = CaptureStats()

    /// - Parameters:
    ///   - capacitySeconds: ring depth at 16 kHz (default 1.0 s — enough to
    ///     absorb engine-queue jitter several times over; drops start only
    ///     past that).
    ///   - sourceSampleRate: declared producer rate (informational + default
    ///     for `submit` when the caller omits it).
    public init(capacitySeconds: Double = 1.0,
                sourceSampleRate: Int = CaptureSpec.sourceSampleRate) {
        precondition(capacitySeconds > 0)
        precondition(sourceSampleRate > 0)
        self.sourceSampleRate = sourceSampleRate
        self.targetSampleRate = CaptureSpec.targetSampleRate
        self.ring = MicRingBuffer(capacitySamples: Int(Double(targetSampleRate) * capacitySeconds))
        if sourceSampleRate != targetSampleRate {
            self.resampler = StreamingResampler(sourceRate: sourceSampleRate,
                                                targetRate: targetSampleRate)
        }
    }

    /// Producer side (audio callback queue). Resamples non-16k input to the
    /// contract rate and writes the ring; ring overflow (oldest content slid
    /// out) is counted as drops. Returns the stats snapshot AFTER this submit.
    @discardableResult
    public func submit(_ samples: [Float],
                       sampleRate: Int? = nil,
                       captureTime_s: Double = 0) -> CaptureStats {
        let rate = sampleRate ?? sourceSampleRate
        lock.lock()
        defer { lock.unlock() }
        stats.submits += 1
        stats.samplesReceived += samples.count

        var chunk = samples
        if rate != targetSampleRate {
            guard rate > 0 else {
                stats.samplesDropped += samples.count // unrecoverable input
                stats.lastDropSamples = samples.count
                stats.drops += 1
                return stats
            }
            if resampler == nil || resampler?.sourceRate != rate {
                resampler = StreamingResampler(sourceRate: rate, targetRate: targetSampleRate)
            }
            resampler?.submit(samples)
            chunk = resampler?.drain() ?? []
        }
        accountRingWrite(chunk)
        return stats
    }

    /// Stream end (capture stopped): flush the resampler's deferred tail.
    public func finish() {
        lock.lock(); defer { lock.unlock() }
        resampler?.flush()
        accountRingWrite(resampler?.drain() ?? [])
    }

    /// Ring write + drop accounting (caller holds `lock`).
    private func accountRingWrite(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        let result = ring.write(chunk)
        stats.samplesWritten += result.written
        if result.overwritten > 0 {
            stats.samplesDropped += result.overwritten
            stats.drops += 1
            stats.lastDropSamples = result.overwritten
        }
    }

    /// Consumer side (engine queue): up to `maxSamples` at 16 kHz.
    public func drain(maxSamples: Int) -> [Float] {
        let out = ring.read(maxSamples: maxSamples)
        lock.lock()
        stats.samplesRead += out.count
        lock.unlock()
        return out
    }

    /// 16 kHz samples currently buffered (ring only, not the resampler tail).
    public var pendingCount: Int { ring.availableCount }

    public func snapshot() -> CaptureStats {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    /// Interruption hook (call from session observers): empties ring +
    /// resampler so the next `submit` starts a clean stream. Stats survive
    /// unless `clearStats` — drop history must not silently vanish.
    public func reset(clearStats: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        ring.clear()
        resampler?.reset()
        if clearStats { stats = CaptureStats() }
    }
}
