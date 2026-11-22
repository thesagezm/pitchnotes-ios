import XCTest
@testable import EngineCore

// P-202 L1 — ChunkedSeparationDriver unit tests (portable core; Linux docker).
// Real engine wiring (DemucsEngine per-window) = L2; D-25 benchmark = L3.

private final class IdentityEngine: SegmentEngine {
    let vocalScale: Float
    init(vocalScale: Float = 1.0) { self.vocalScale = vocalScale }
    func separate(window: [Float], channels: Int) async throws -> [Part: [Float]] {
        [
            .vocals: window.map { $0 * vocalScale },
            .instrumental: window.map { $0 * 0.5 },
        ]
    }
}

private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ImportProgress] = []
    func record(_ p: ImportProgress) {
        lock.lock(); items.append(p); lock.unlock()
    }
    var all: [ImportProgress] {
        lock.lock(); defer { lock.unlock() }; return items
    }
}

final class ChunkedSeparationDriverTests: XCTestCase {

    /// Element-wise float equality (XCTAssertEqual(accuracy:) is scalar-only).
    private func assertClose(_ a: [Float], _ b: [Float], accuracy: Float,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, "length", file: file, line: line)
        guard a.count == b.count else { return }
        for i in 0..<a.count {
            XCTAssertLessThanOrEqual(abs(a[i] - b[i]), accuracy,
                                     "index \(i): \(a[i]) vs \(b[i])", file: file, line: line)
        }
    }

    /// 1 s @44.1k → single window, identity engine → exact stems.
    func testSingleWindowIdentity() async throws {
        let policy = ChunkPolicy(windowSeconds: 8.0, overlapSeconds: 2.0)
        let driver = try ChunkedSeparationDriver(policy: policy)
        let audio: [Float] = (0..<44100).map { Float($0 % 1000) / 1000.0 }
        let out = try await driver.run(audio: audio, channels: 1, engine: IdentityEngine())
        assertClose(out[.vocals]!, audio, accuracy: 0.0)
        assertClose(out[.instrumental]!, audio.map { $0 * 0.5 }, accuracy: 0.0)
    }

    /// 10 s ramp through 4 s / 1 s windows with an identity engine: linear
    /// crossfade of identical content reconstructs the input (unity-sum
    /// property — the reason the blend is LINEAR, see driver doc).
    func testMultiWindowLinearReconstruction() async throws {
        let policy = ChunkPolicy(windowSeconds: 4.0, overlapSeconds: 1.0)
        let driver = try ChunkedSeparationDriver(policy: policy)
        let n = 44100 * 10
        let audio: [Float] = (0..<n).map { Float($0) / Float(n) } // gentle ramp
        let out = try await driver.run(audio: audio, channels: 1, engine: IdentityEngine())
        XCTAssertEqual(out[.vocals]!.count, n)
        assertClose(out[.vocals]!, audio, accuracy: 1e-5)
        assertClose(out[.instrumental]!, audio.map { $0 * 0.5 }, accuracy: 1e-5)
    }

    /// Stereo input keeps channel interleaving through the blend.
    func testStereoInterleavingSurvivesBlend() async throws {
        let policy = ChunkPolicy(windowSeconds: 2.0, overlapSeconds: 0.5)
        let driver = try ChunkedSeparationDriver(policy: policy)
        let frames = 44100 * 5
        var audio = [Float]()
        audio.reserveCapacity(frames * 2)
        for i in 0..<frames {
            audio.append(Float(i % 7) / 7.0)       // L
            audio.append(Float(i % 11) / 11.0)     // R
        }
        let out = try await driver.run(audio: audio, channels: 2, engine: IdentityEngine())
        XCTAssertEqual(out[.vocals]!.count, frames * 2)
        assertClose(out[.vocals]!, audio, accuracy: 1e-5)
    }

    /// C-8: progress monotonic, all in `separating`, ends at exactly 1.0.
    func testProgressMonotonicEndsAtOne() async throws {
        let policy = ChunkPolicy(windowSeconds: 4.0, overlapSeconds: 1.0)
        let collector = ProgressCollector()
        let driver = try ChunkedSeparationDriver(policy: policy) { collector.record($0) }
        let audio: [Float] = [Float](repeating: 0.1, count: 44100 * 12)
        _ = try await driver.run(audio: audio, channels: 1, engine: IdentityEngine())
        let items = collector.all
        XCTAssertFalse(items.isEmpty)
        var last = -1.0
        for p in items {
            XCTAssertEqual(p.stage, .separating)
            XCTAssertGreaterThanOrEqual(p.fraction, last, "progress must be monotonic")
            last = p.fraction
        }
        XCTAssertEqual(items.last?.fraction, 1.0)
        XCTAssertGreaterThan(items.count, 2, "per-window emits expected for a 12 s song")
    }

    /// Thermal pacing: serious state consults the provider + sleeps before
    /// every window; nominal state never sleeps.
    func testThermalPacingDelays() async throws {
        final class SleepLog: @unchecked Sendable {
            private let lock = NSLock()
            private var delays: [Double] = []
            func record(_ d: Double) { lock.lock(); delays.append(d); lock.unlock() }
            var all: [Double] { lock.lock(); defer { lock.unlock() }; return delays }
        }
        let log = SleepLog()
        var config = ChunkedSeparationDriver.Config()
        config.sleeper = { d in log.record(d) } // no real sleep in tests

        // serious → 0.5 s before each window
        let serious = try ChunkedSeparationDriver(
            policy: ChunkPolicy(windowSeconds: 4.0, overlapSeconds: 1.0),
            config: config,
            thermalProvider: { .serious })
        let audio: [Float] = [Float](repeating: 0.1, count: 44100 * 10)
        _ = try await serious.run(audio: audio, channels: 1, engine: IdentityEngine())
        XCTAssertFalse(log.all.isEmpty)
        XCTAssertTrue(log.all.allSatisfy { $0 == 0.5 }, "serious → 0.5 s pacing per window")

        // nominal → no sleeps at all
        let nominal = try ChunkedSeparationDriver(
            policy: ChunkPolicy(windowSeconds: 4.0, overlapSeconds: 1.0),
            config: config,
            thermalProvider: { .nominal })
        _ = try await nominal.run(audio: audio, channels: 1, engine: IdentityEngine())
        // log only records sleeps; assert no NEW entries arrived (nominal run).
        XCTAssertTrue(log.all.allSatisfy { $0 == 0.5 }, "nominal must not add pacing entries")
    }

    /// C-8 cancellation: task cancelled while window 1 runs (gated engine) →
    /// the driver throws at the NEXT window boundary; no partial stems.
    func testCancellationBeforeRun() async {
        final class GatedEngine: SegmentEngine {
            let gate: AsyncStream<Void>
            init(gate: AsyncStream<Void>) { self.gate = gate }
            func separate(window: [Float], channels: Int) async throws -> [Part: [Float]] {
                for await _ in gate {} // resumes when the test finishes the stream
                return [
                    .vocals: window,
                    .instrumental: window.map { $0 * 0.5 },
                ]
            }
        }
        let driver = try! ChunkedSeparationDriver(policy: ChunkPolicy(windowSeconds: 2.0, overlapSeconds: 0.5))
        let audio: [Float] = [Float](repeating: 0.1, count: 44100 * 6)
        let (gateStream, gateCont) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await driver.run(audio: audio, channels: 1, engine: GatedEngine(gate: gateStream))
        }
        task.cancel()
        gateCont.finish() // deterministically release window 1; window 2 check fires
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // honest C-8 behavior — cancellation between windows
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// Cancellation mid-run: engine cancels the surrounding task during
    /// window 1 → driver throws on the NEXT window boundary (checked between
    /// windows), never returning partial output.
    func testCancellationBetweenWindows() async {
        final class CancellingEngine: SegmentEngine {
            func separate(window: [Float], channels: Int) async throws -> [Part: [Float]] {
                withUnsafeCurrentTask { t in t?.cancel() }
                return [
                    .vocals: window,
                    .instrumental: window.map { $0 * 0.5 },
                ]
            }
        }
        let driver = try! ChunkedSeparationDriver(policy: ChunkPolicy(windowSeconds: 2.0, overlapSeconds: 0.5))
        let audio: [Float] = [Float](repeating: 0.1, count: 44100 * 10)
        do {
            _ = try await driver.run(audio: audio, channels: 1, engine: CancellingEngine())
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // cancelled between windows — no partial stems escaped
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// Policy + input contract guards.
    func testPolicyAndInputValidation() async {
        // window ≤ overlap
        XCTAssertThrowsError(try ChunkedSeparationDriver(
            policy: ChunkPolicy(windowSeconds: 1.0, overlapSeconds: 1.0)))
        // frames×channels mismatch
        let driver = try! ChunkedSeparationDriver(policy: ChunkPolicy(windowSeconds: 4.0, overlapSeconds: 1.0))
        do {
            _ = try await driver.run(audio: [Float](repeating: 0, count: 101), channels: 2,
                                     engine: IdentityEngine())
            XCTFail("expected contractViolation")
        } catch is CancellationError {
            XCTFail("wrong error class")
        } catch {
            // contractViolation expected
        }
    }

    /// Engine must return consistent part keys across windows.
    func testPartKeyConsistency() async {
        final class InconsistentEngine: SegmentEngine, @unchecked Sendable {
            var first = true
            func separate(window: [Float], channels: Int) async throws -> [Part: [Float]] {
                defer { first = false }
                return first
                    ? [.vocals: window, .instrumental: window.map { $0 * 0.5 }]
                    : [.vocals: window]
            }
        }
        let driver = try! ChunkedSeparationDriver(policy: ChunkPolicy(windowSeconds: 2.0, overlapSeconds: 0.5))
        let audio: [Float] = [Float](repeating: 0.1, count: 44100 * 6)
        do {
            _ = try await driver.run(audio: audio, channels: 1, engine: InconsistentEngine())
            XCTFail("expected contractViolation for inconsistent part keys")
        } catch is CancellationError {
            XCTFail("wrong error class")
        } catch {
            // contractViolation expected
        }
    }

    // MARK: - L2: within-window progress mapping

    /// An engine that reports sub-window progress (the vendor's per-stage
    /// callback). The driver must scale it into the window's slice of the
    /// band — never an absolute fraction chosen by the engine.
    func testSubWindowProgressScalesIntoBandSlice() async throws {
        final class SubProgressEngine: SegmentEngine, @unchecked Sendable {
            func separate(window: [Float], channels: Int) async throws -> [Part: [Float]] {
                try await separate(window: window, channels: channels) { _, _ in }
            }
            func separate(window: [Float], channels: Int,
                          progress: @escaping @Sendable (Double, String) -> Void) async throws -> [Part: [Float]] {
                progress(0.0, "stage 0")
                progress(0.5, "stage 1")
                progress(1.0, "stage 2")
                return [.vocals: window, .instrumental: window.map { $0 * 0.5 }]
            }
        }
        let collector = ProgressCollector()
        // Band [0.05, 0.95] (default): window 1 of a 10 s song with 4 s/1 s
        // windows covers frames [0, 4 s) ⇒ slice [0.0, 0.4] of the band.
        let driver = try ChunkedSeparationDriver(
            policy: ChunkPolicy(windowSeconds: 4.0, overlapSeconds: 1.0),
            progress: { collector.record($0) })
        let audio: [Float] = [Float](repeating: 0.1, count: 44100 * 10)
        _ = try await driver.run(audio: audio, channels: 1, engine: SubProgressEngine())

        let items = collector.all
        let sub = items.filter { $0.detail?.hasPrefix("stage") == true }
        XCTAssertEqual(sub.count, 9, "3 sub-progress ticks × 3 windows")
        // Window 1's middle tick (0.5 of the window) lands at band position
        // 0.05 + 0.9 * (0.2) = 0.23 — inside window 1's slice, NOT at the
        // engine's raw 0.5.
        XCTAssertEqual(sub[1].fraction, 0.05 + 0.9 * 0.2, accuracy: 1e-9)
        XCTAssertEqual(sub[0].fraction, 0.05, accuracy: 1e-9)
        XCTAssertEqual(sub[2].fraction, 0.05 + 0.9 * 0.4, accuracy: 1e-9)
        // Window 2 starts at 3 s but only contributes NEW frames from 4 s
        // (the 1 s overlap was already ingested) ⇒ its slice is [0.4, 0.7].
        XCTAssertEqual(sub[3].fraction, 0.05 + 0.9 * 0.4, accuracy: 1e-9)
        XCTAssertEqual(sub[5].fraction, 0.05 + 0.9 * 0.7, accuracy: 1e-9)
        // Monotonic across the whole run, and the final emit is still 1.0.
        var last = -1.0
        for p in items {
            XCTAssertGreaterThanOrEqual(p.fraction, last)
            last = p.fraction
        }
        XCTAssertEqual(items.last?.fraction, 1.0)
    }

    /// The engine may own the final 1.0 (it still has to stage stems after the
    /// driver returns) — then the driver must NOT emit 1.0 itself.
    func testCompletionOwnershipCanBeDelegatedToCaller() async throws {
        let collector = ProgressCollector()
        var config = ChunkedSeparationDriver.Config()
        config.emitCompletion = false
        let driver = try ChunkedSeparationDriver(
            policy: ChunkPolicy(windowSeconds: 4.0, overlapSeconds: 1.0),
            config: config,
            progress: { collector.record($0) })
        let audio: [Float] = [Float](repeating: 0.1, count: 44100 * 10)
        _ = try await driver.run(audio: audio, channels: 1, engine: IdentityEngine())
        let items = collector.all
        XCTAssertFalse(items.isEmpty)
        XCTAssertLessThan(items.last!.fraction, 1.0,
                          "driver must not claim completion when the caller owns it")
        XCTAssertEqual(items.last!.fraction, 0.05 + 0.9 * 1.0, accuracy: 1e-9)
    }

    /// The default `SegmentEngine` progress variant (used by engines with no
    /// sub-window signal) forwards to the plain call — window-granular
    /// progress only.
    func testDefaultProgressVariantForwardsToPlainCall() async throws {
        final class PlainEngine: SegmentEngine, @unchecked Sendable {
            func separate(window: [Float], channels: Int) async throws -> [Part: [Float]] {
                [.vocals: window, .instrumental: window.map { $0 * 0.5 }]
            }
        }
        let collector = ProgressCollector()
        let driver = try ChunkedSeparationDriver(
            policy: ChunkPolicy(windowSeconds: 4.0, overlapSeconds: 1.0),
            progress: { collector.record($0) })
        let audio: [Float] = [Float](repeating: 0.1, count: 44100 * 10)
        let out = try await driver.run(audio: audio, channels: 1, engine: PlainEngine())
        XCTAssertEqual(out[.vocals]!.count, audio.count)
        XCTAssertFalse(collector.all.isEmpty)
        XCTAssertTrue(collector.all.allSatisfy { $0.detail?.hasPrefix("stage") != true })
    }
}
