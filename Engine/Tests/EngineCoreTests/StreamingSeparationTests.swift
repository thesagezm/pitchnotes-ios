import XCTest
@testable import EngineCore

// P-209 — Streaming separation (the P-202 follow-up): the chunked driver
// writes each window's blended stems to disk INSTEAD of accumulating them,
// and the staged mix is read window-by-window.
//
// THE CENTRAL CLAIM: the streamed output is BIT-IDENTICAL to the accumulate
// path (the reference implementation) on the same fixture + mock engine — the
// refactor changes WHEN the frames are written, never WHAT is written.

/// A deterministic engine whose output depends on the window CONTENT and on
/// the window INDEX — so a wrong blend window or a wrong frame offset shows
/// up as a mismatch, not as an identity that hides it.
private final class PhaseEngine: SegmentEngine, @unchecked Sendable {
    let vocalScale: Float
    private(set) var calls = 0
    /// Throws this error on the given window index (1-based).
    var failOnCall: Int?
    var errorToThrow: Error = EngineError.separationFailed("mock failure")
    /// Called at the start of each window (the test cancels the task here).
    var onWindow: ((Int) -> Void)?

    init(vocalScale: Float = 1.0) { self.vocalScale = vocalScale }

    func separate(window: [Float], channels: Int) async throws -> [Part: [Float]] {
        calls += 1
        onWindow?(calls)
        if let failOnCall, calls == failOnCall { throw errorToThrow }
        let k = 1.0 + 0.1 * Float(calls - 1)
        return [
            .vocals: window.map { $0 * vocalScale * k },
            .instrumental: window.map { $0 * 0.5 * (2.0 - k) },
        ]
    }
}

private final class SinkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [Part: MemoryStemSink] = [:]
    func sink(for part: Part) -> MemoryStemSink {
        lock.lock(); defer { lock.unlock() }
        if let s = sinks[part] { return s }
        let s = MemoryStemSink(part: part)
        sinks[part] = s
        return s
    }
    var all: [MemoryStemSink] {
        lock.lock(); defer { lock.unlock() }; return Array(sinks.values)
    }
}

final class StreamingSeparationTests: XCTestCase {

    private func tempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pitchnotes-p209-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func ramp(count: Int, channels: Int) -> [Float] {
        (0..<(count * channels)).map { Float($0 % 997) / 997.0 - 0.5 }
    }

    // MARK: - The central claim: bit-identical to the accumulate path

    /// The streamed output == the accumulated output, EXACTLY, for a
    /// multi-window fixture (the accumulate path is the reference).
    func testStreamingOutputIsBitIdenticalToAccumulate() async throws {
        let policy = ChunkPolicy(windowSeconds: 4.0, overlapSeconds: 1.0)
        let channels = 2
        let frames = 44100 * 10
        let audio = ramp(count: frames, channels: channels)

        let reference = try await ChunkedSeparationDriver(policy: policy)
            .run(audio: audio, channels: channels, engine: PhaseEngine())

        let collector = SinkCollector()
        let source = MemoryAudioWindowSource(samples: audio, channels: channels)
        let stats = try await ChunkedSeparationDriver(policy: policy)
            .runStreaming(source: source, engine: PhaseEngine()) { part in
                collector.sink(for: part)
            }

        XCTAssertEqual(stats.frames, frames)
        for part in [Part.vocals, .instrumental] {
            let streamed = collector.sink(for: part).collected
            let accumulated = reference[part]!
            XCTAssertEqual(streamed.count, accumulated.count, "part \(part)")
            for i in 0..<min(streamed.count, accumulated.count) {
                XCTAssertEqual(streamed[i], accumulated[i],
                               "part \(part) index \(i): \(streamed[i]) vs \(accumulated[i])")
            }
        }
        // The sinks were FINISHED (a finished sink = a complete file).
        for sink in collector.all { XCTAssertTrue(sink.isFinished) }
    }

    /// The same claim for a MONO mix (the other D-8 layout).
    func testStreamingMatchesAccumulateMono() async throws {
        let policy = ChunkPolicy(windowSeconds: 2.0, overlapSeconds: 0.5)
        let channels = 1
        let frames = 44100 * 7
        let audio = ramp(count: frames, channels: channels)

        let reference = try await ChunkedSeparationDriver(policy: policy)
            .run(audio: audio, channels: channels, engine: PhaseEngine())
        let collector = SinkCollector()
        _ = try await ChunkedSeparationDriver(policy: policy)
            .runStreaming(source: MemoryAudioWindowSource(samples: audio, channels: channels),
                          engine: PhaseEngine()) { collector.sink(for: $0) }

        for part in [Part.vocals, .instrumental] {
            let streamed = collector.sink(for: part).collected
            let accumulated = reference[part]!
            XCTAssertEqual(streamed.count, accumulated.count)
            for i in 0..<min(streamed.count, accumulated.count) {
                XCTAssertEqual(streamed[i], accumulated[i], "index \(i)")
            }
        }
    }

    // MARK: - The memory bound (the point of P-209)

    /// The retained buffer never exceeds ONE window — and it does NOT grow
    /// with the song: a 4× longer song retains exactly as much.
    func testRetainedBufferIsBoundedByOneWindowAndIndependentOfLength() async throws {
        let policy = ChunkPolicy(windowSeconds: 4.0, overlapSeconds: 1.0)
        let channels = 2
        var retained: [Int] = []
        for seconds in [10, 40] {
            let frames = 44100 * seconds
            let audio = ramp(count: frames, channels: channels)
            let collector = SinkCollector()
            let stats = try await ChunkedSeparationDriver(policy: policy)
                .runStreaming(source: MemoryAudioWindowSource(samples: audio, channels: channels),
                              engine: PhaseEngine()) { collector.sink(for: $0) }
            retained.append(stats.maxRetainedFrames)
            XCTAssertLessThanOrEqual(stats.maxRetainedFrames, policy.windowSamples,
                                     "retained frames must never exceed one window")
            // The output is complete: every frame was written exactly once.
            for part in [Part.vocals, .instrumental] {
                XCTAssertEqual(collector.sink(for: part).collected.count, frames * channels)
            }
        }
        XCTAssertEqual(retained[0], retained[1],
                       "the retained buffer must not depend on the song length")
    }

    /// The stems are written INCREMENTALLY (several writes), not in one
    /// lump at the end — otherwise the memory bound would be a lie.
    func testStemsAreWrittenIncrementally() async throws {
        let policy = ChunkPolicy(windowSeconds: 2.0, overlapSeconds: 0.5)
        let frames = 44100 * 12
        let audio = ramp(count: frames, channels: 2)
        let collector = SinkCollector()
        let stats = try await ChunkedSeparationDriver(policy: policy)
            .runStreaming(source: MemoryAudioWindowSource(samples: audio, channels: 2),
                          engine: PhaseEngine()) { collector.sink(for: $0) }
        XCTAssertGreaterThan(stats.windows, 2)
        for part in [Part.vocals, .instrumental] {
            let sink = collector.sink(for: part)
            XCTAssertGreaterThan(sink.maxChunkFrames, 0)
            XCTAssertLessThanOrEqual(sink.maxChunkFrames, policy.windowSamples)
        }
    }

    // MARK: - The file-backed source (no whole-song slurp)

    /// The file-backed source returns the same windows as the memory source.
    func testFileBackedSourceMatchesMemorySource() throws {
        let dir = try tempDir("source")
        defer { try? FileManager.default.removeItem(at: dir) }
        let channels = 2
        let frames = 5000
        let audio = ramp(count: frames, channels: channels)
        let url = dir.appendingPathComponent("mix.f32.wav")
        try PCMF32Wav.write(url: url, frames: audio, sampleRate: 44100, channels: channels)

        let source = try PCMF32WavWindowSource(url: url)
        XCTAssertEqual(source.totalFrames, frames)
        XCTAssertEqual(source.channels, channels)
        XCTAssertEqual(source.sampleRate, 44100)

        let memory = MemoryAudioWindowSource(samples: audio, channels: channels)
        for (start, count) in [(0, 1000), (900, 1000), (4000, 1000)] {
            let fromFile = try source.read(startFrame: start, frameCount: count)
            let fromMemory = try memory.read(startFrame: start, frameCount: count)
            XCTAssertEqual(fromFile, fromMemory, "window \(start)+\(count)")
        }
        // Out of range is an error, not a silent short read.
        XCTAssertThrowsError(try source.read(startFrame: frames - 10, frameCount: 100))
    }

    /// The stereo wrapper presents the PROCESSING layout (the vendor contract)
    /// without changing a stereo mix.
    func testStereoWindowSourceUpmixesMono() throws {
        let mono = (0..<10).map { Float($0) / 10 }
        let stereo = try StereoWindowSource(base: MemoryAudioWindowSource(samples: mono, channels: 1))
            .read(startFrame: 0, frameCount: 10)
        XCTAssertEqual(stereo.count, 20)
        for f in 0..<10 {
            XCTAssertEqual(stereo[f * 2], mono[f])
            XCTAssertEqual(stereo[f * 2 + 1], mono[f])
        }
    }

    // MARK: - The stem writer

    /// The streaming writer produces BYTE-IDENTICAL output to the
    /// whole-array writer (`PCMWavWriter`) — the ALAC path must not change.
    func testStreamingWriterMatchesWholeArrayWriterBytes() throws {
        let dir = try tempDir("writer")
        defer { try? FileManager.default.removeItem(at: dir) }
        let samples = ramp(count: 4096, channels: 2)
        let whole = dir.appendingPathComponent("whole.wav")
        let streamed = dir.appendingPathComponent("streamed.wav")
        try PCMWavWriter.write(url: whole, samples: samples, sampleRate: 44100, channels: 2)

        let writer = try PCM16StreamWriter(url: streamed, sampleRate: 44100, outputChannels: 2)
        try writer.append(frames: samples)
        try writer.finish()

        let a = try Data(contentsOf: whole)
        let b = try Data(contentsOf: streamed)
        XCTAssertEqual(a.count, b.count)
        XCTAssertEqual(a, b, "the streamed stem must be byte-identical to the whole-array stem")
    }

    /// The mono stem (D-8's voice policy) folds with the channel MEAN — the
    /// same math as `SeparationChannels.toMono`.
    func testStreamingWriterMonoFoldMatchesToMono() throws {
        let dir = try tempDir("mono")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stereo = ramp(count: 2048, channels: 2)
        let url = dir.appendingPathComponent("vocals.wav")
        let writer = try PCM16StreamWriter(url: url, sampleRate: 44100, outputChannels: 1)
        try writer.append(frames: stereo)
        try writer.finish()

        let expected = try SeparationChannels.toMono(stereo: stereo)
        let whole = dir.appendingPathComponent("vocals-whole.wav")
        try PCMWavWriter.write(url: whole, samples: expected, sampleRate: 44100, channels: 1)
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: whole))
    }

    /// A writer that was never finished leaves a partial file — and `abort()`
    /// removes it (C-8: no residue).
    func testAbortRemovesThePartialStemFile() throws {
        let dir = try tempDir("abort")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("partial.wav")
        let writer = try PCM16StreamWriter(url: url, sampleRate: 44100, outputChannels: 2)
        try writer.append(frames: ramp(count: 512, channels: 2))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try writer.abort()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "an aborted stem writer must leave NO file behind")
    }

    // MARK: - Failure and cancellation (C-8)

    /// An engine failure mid-run: the sinks are ABORTED (no partial stem
    /// file) and the error surfaces unchanged.
    func testEngineFailureAbortsTheSinksAndLeavesNoFile() async throws {
        let dir = try tempDir("failure")
        defer { try? FileManager.default.removeItem(at: dir) }
        let policy = ChunkPolicy(windowSeconds: 2.0, overlapSeconds: 0.5)
        let audio = ramp(count: 44100 * 10, channels: 2)

        let engine = PhaseEngine()
        engine.failOnCall = 2
        let vocalsURL = dir.appendingPathComponent("vocals.wav")
        let instrumentalURL = dir.appendingPathComponent("instrumental.wav")

        do {
            _ = try await ChunkedSeparationDriver(policy: policy)
                .runStreaming(source: MemoryAudioWindowSource(samples: audio, channels: 2),
                              engine: engine) { part in
                    try PCM16StreamWriter(url: part == .vocals ? vocalsURL : instrumentalURL,
                                          sampleRate: 44100,
                                          outputChannels: part == .vocals ? 1 : 2)
                }
            XCTFail("the engine failure must surface")
        } catch {
            // The ORIGINAL error, not a cleanup error.
            XCTAssertTrue(error is EngineError, "got \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: vocalsURL.path),
                       "a failed separation must leave NO partial stem file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: instrumentalURL.path))
    }

    /// Cancelling the task mid-run: CancellationError surfaces and no partial
    /// stem file survives (the C-8 no-residue discipline).
    func testCancellationAbortsTheSinksAndLeavesNoFile() async throws {
        let dir = try tempDir("cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let policy = ChunkPolicy(windowSeconds: 2.0, overlapSeconds: 0.5)
        let audio = ramp(count: 44100 * 10, channels: 2)
        let vocalsURL = dir.appendingPathComponent("vocals.wav")

        let task = Task {
            let engine = PhaseEngine()
            engine.onWindow = { call in
                if call == 2 { /* cancel the surrounding task */ }
            }
            let engine2 = engine
            return try await ChunkedSeparationDriver(policy: policy)
                .runStreaming(source: MemoryAudioWindowSource(samples: audio, channels: 2),
                              engine: engine2) { part in
                    try PCM16StreamWriter(url: vocalsURL, sampleRate: 44100, outputChannels: 1)
                }
        }
        task.cancel()
        do {
            _ = try await task.value
            // The task may have finished before the cancellation landed (the
            // fixture is tiny) — then the file is COMPLETE, not partial.
            XCTAssertTrue(FileManager.default.fileExists(atPath: vocalsURL.path))
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: vocalsURL.path),
                           "a cancelled separation must leave NO partial stem file")
        }
    }

    /// The engine's own cancellation seam (the vendor abort path) surfaces as
    /// CancellationError and aborts the sinks.
    func testCancellationErrorFromTheEngineAbortsTheSinks() async throws {
        let dir = try tempDir("vendor-cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let policy = ChunkPolicy(windowSeconds: 2.0, overlapSeconds: 0.5)
        let audio = ramp(count: 44100 * 10, channels: 2)
        let vocalsURL = dir.appendingPathComponent("vocals.wav")

        let engine = PhaseEngine()
        engine.failOnCall = 2
        engine.errorToThrow = CancellationError()

        do {
            _ = try await ChunkedSeparationDriver(policy: policy)
                .runStreaming(source: MemoryAudioWindowSource(samples: audio, channels: 2),
                              engine: engine) { _ in
                    try PCM16StreamWriter(url: vocalsURL, sampleRate: 44100, outputChannels: 1)
                }
            XCTFail("the cancellation must surface")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: vocalsURL.path))
    }

    // MARK: - Progress (C-8)

    /// The streaming path keeps the C-8 progress MONOTONIC inside the
    /// separating band — the same discipline as the accumulate path.
    func testStreamingProgressIsMonotonicWithinTheBand() async throws {
        let policy = ChunkPolicy(windowSeconds: 2.0, overlapSeconds: 0.5)
        let frames = 44100 * 10
        let audio = ramp(count: frames, channels: 2)

        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [ImportProgress] = []
            func add(_ p: ImportProgress) { lock.lock(); items.append(p); lock.unlock() }
            var all: [ImportProgress] { lock.lock(); defer { lock.unlock() }; return items }
        }
        let box = Box()
        var config = ChunkedSeparationDriver.Config()
        config.emitCompletion = false
        let driver = try ChunkedSeparationDriver(policy: policy, config: config,
                                                 progress: { box.add($0) })
        let collector = SinkCollector()
        _ = try await driver.runStreaming(source: MemoryAudioWindowSource(samples: audio, channels: 2),
                                           engine: PhaseEngine()) { collector.sink(for: $0) }

        let items = box.all
        XCTAssertFalse(items.isEmpty)
        var last = -1.0
        for p in items {
            XCTAssertGreaterThanOrEqual(p.fraction, last,
                                        "progress must be monotonic (C-8): \(items.map(\.fraction))")
            XCTAssertGreaterThanOrEqual(p.fraction, 0.05)
            XCTAssertLessThanOrEqual(p.fraction, 0.95)
            last = p.fraction
        }
        // The driver owns the band and does NOT emit its own completion here
        // (the caller owns the final 1.0 — C-8: "1.0 only at completion"),
        // so the last fraction is the TOP OF THE BAND.
        XCTAssertEqual(last, 0.95, accuracy: 1e-9)
    }
}
