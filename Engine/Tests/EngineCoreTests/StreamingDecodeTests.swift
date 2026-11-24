import Foundation
import XCTest
@testable import EngineCore

// P-210: streaming decode→stage — the import path's last O(song) term.
//
// THE CLAIM UNDER TEST: the streamed staging mix is BYTE-IDENTICAL to the
// whole-buffer path, and the streamed 16 kHz mono signal (the tuning
// estimator's input) is BIT-IDENTICAL to the whole-file path — while the
// retained memory does NOT grow with the song length.
//
// The whole-buffer path (`normalizeAndStage` / `PCMF32Wav.write` /
// `PCMF32Wav.read`) stays in the tree as the REFERENCE implementation.

final class StreamingDecodeTests: XCTestCase {

    private func tempDir(_ name: String) -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("p210-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func cleanup(_ dirs: URL...) {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
    }

    /// Deterministic pseudo-random signal (no Math.random — reproducible).
    private func noise(_ n: Int, seed: UInt64 = 0x5EED) -> [Float] {
        var state = seed
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Float(Double(state >> 11) / Double(UInt64(1) << 53)) * 2 - 1
            out[i] = unit * 0.7
        }
        return out
    }

    private func sine(_ n: Int, freq: Double = 440.0, sr: Int = 44100) -> [Float] {
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = Float(sin(2.0 * Double.pi * freq * Double(i) / Double(sr)))
        }
        return out
    }

    /// Interleaves per-channel planes.
    private func interleave(_ planes: [[Float]]) -> [Float] {
        let channels = planes.count
        let frames = planes[0].count
        var out = [Float](repeating: 0, count: frames * channels)
        for f in 0..<frames {
            for c in 0..<channels { out[f * channels + c] = planes[c][f] }
        }
        return out
    }

    // MARK: - 1) The streaming resampler is bit-identical to the whole-buffer one

    func testStreamingResamplerIsBitIdenticalToWholeBuffer() {
        let pairs = [(48000, 44100), (44100, 16000), (22050, 44100), (96000, 44100),
                     (32000, 44100), (44100, 44100)]
        for (sourceRate, targetRate) in pairs {
            for length in [1, 17, 1000, 44100] {
                let input = noise(length, seed: UInt64(sourceRate &+ length))
                let reference = AudioResampler.resample(samples: input,
                                                        sourceRate: sourceRate,
                                                        targetRate: targetRate)
                let streaming = StreamingAudioResampler(sourceRate: sourceRate,
                                                        targetRate: targetRate)
                var out: [Float] = []
                out.append(contentsOf: streaming.push(input))
                out.append(contentsOf: streaming.finish())
                XCTAssertEqual(out.count, reference.count,
                               "count mismatch \(sourceRate)->\(targetRate) len \(length)")
                XCTAssertEqual(out, reference,
                               "resample mismatch \(sourceRate)->\(targetRate) len \(length)")
            }
        }
    }

    /// The chunking must not change a single sample.
    func testStreamingResamplerIsChunkIndependent() {
        let input = noise(20000)
        let reference = AudioResampler.resample(samples: input, sourceRate: 48000,
                                                targetRate: 44100)
        for chunkSize in [1, 7, 333, 4096, 20000] {
            let streaming = StreamingAudioResampler(sourceRate: 48000, targetRate: 44100)
            var out: [Float] = []
            var offset = 0
            while offset < input.count {
                let end = min(offset + chunkSize, input.count)
                out.append(contentsOf: streaming.push(Array(input[offset..<end])))
                offset = end
            }
            out.append(contentsOf: streaming.finish())
            XCTAssertEqual(out, reference, "chunk size \(chunkSize) changed the output")
        }
    }

    // MARK: - 2) The staged WAV is byte-identical to the whole-buffer path

    func testStagedWavIsByteIdenticalToTheWholeBufferPath() throws {
        let cases: [(sr: Int, ch: Int, frames: Int)] = [
            (44100, 1, 5000), (44100, 2, 5000), (48000, 2, 5000),
            (22050, 2, 3000), (32000, 1, 4000), (96000, 2, 2000), (44100, 3, 2000),
        ]
        for testCase in cases {
            let dir = tempDir("stage-\(testCase.sr)-\(testCase.ch)")
            defer { cleanup(dir) }
            let planes = (0..<testCase.ch).map { c in
                sine(testCase.frames, freq: 220.0 * Double(c + 1), sr: testCase.sr)
            }
            let interleaved = interleave(planes)

            // REFERENCE: the whole-buffer path (unchanged).
            let reference = try WavSourceDecoder.normalizeAndStage(
                (samples: interleaved, sampleRate: testCase.sr, channels: testCase.ch),
                workDir: dir)

            // STREAMED: the new path, chunked.
            let streamedURL = dir.appendingPathComponent("streamed-mix.f32.wav")
            let stager = try StreamingMixStager(url: streamedURL,
                                                sourceSampleRate: testCase.sr,
                                                sourceChannels: testCase.ch)
            var offset = 0
            while offset < interleaved.count {
                let end = min(offset + 997 * testCase.ch, interleaved.count)
                try stager.push(interleaved: Array(interleaved[offset..<end]))
                offset = end
            }
            let streamed = try stager.finish()

            let referenceBytes = try Data(contentsOf: reference.url)
            let streamedBytes = try Data(contentsOf: streamedURL)
            XCTAssertEqual(streamedBytes, referenceBytes,
                           "staged bytes differ (\(testCase.sr) Hz / \(testCase.ch) ch)")
            XCTAssertEqual(streamed.duration_s, reference.duration_s, accuracy: 1e-12)
            XCTAssertEqual(streamed.channels, reference.channels)
            XCTAssertEqual(streamed.sampleRate, reference.sampleRate)
        }
    }

    /// The chunk size must not change the staged bytes either.
    func testStagedBytesAreChunkIndependent() throws {
        let dir = tempDir("chunk-independent")
        defer { cleanup(dir) }
        let interleaved = interleave([sine(9000), sine(9000, freq: 330)])
        var referenceBytes: Data?
        for chunkSize in [1, 13, 1024, 4096, 100_000] {
            let url = dir.appendingPathComponent("mix-\(chunkSize).f32.wav")
            let stager = try StreamingMixStager(url: url, sourceSampleRate: 48000,
                                                sourceChannels: 2)
            var offset = 0
            while offset < interleaved.count {
                let end = min(offset + chunkSize * 2, interleaved.count)
                try stager.push(interleaved: Array(interleaved[offset..<end]))
                offset = end
            }
            _ = try stager.finish()
            let bytes = try Data(contentsOf: url)
            if let referenceBytes {
                XCTAssertEqual(bytes, referenceBytes, "chunk size \(chunkSize) changed the bytes")
            } else {
                referenceBytes = bytes
            }
        }
    }

    // MARK: - 3) The retained memory does NOT grow with the song length

    func testRetainedFrameBoundDoesNotGrowWithSongLength() throws {
        let dir = tempDir("retained")
        defer { cleanup(dir) }
        var bounds: [Int] = []
        for seconds in [1, 4, 10, 40] {
            let frames = 44100 * seconds
            let interleaved = interleave([sine(frames), sine(frames, freq: 330)])
            let url = dir.appendingPathComponent("mix-\(seconds).f32.wav")
            let stager = try StreamingMixStager(url: url, sourceSampleRate: 44100,
                                                sourceChannels: 2)
            var offset = 0
            while offset < interleaved.count {
                let end = min(offset + 8192 * 2, interleaved.count)
                try stager.push(interleaved: Array(interleaved[offset..<end]))
                offset = end
            }
            _ = try stager.finish()
            bounds.append(stager.retainedFrameBound)
        }
        XCTAssertEqual(Set(bounds).count, 1,
                       "the retained-frame bound changed with the song length: \(bounds)")
        XCTAssertLessThan(bounds[0], 20_000,
                          "the retained bound should be a window, not the song")
    }

    // MARK: - 4) A failed/aborted stage leaves NO residue (C-2.2)

    func testAbortRemovesThePartialStagingFile() throws {
        let dir = tempDir("abort")
        defer { cleanup(dir) }
        let url = dir.appendingPathComponent("partial-mix.f32.wav")
        let stager = try StreamingMixStager(url: url, sourceSampleRate: 44100,
                                            sourceChannels: 2)
        try stager.push(interleaved: interleave([sine(4096), sine(4096, freq: 330)]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "the partial file should exist before the abort")
        stager.abort()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "the partial staging file survived the abort")
    }

    // MARK: - 5) The file-backed reader matches the whole-file parse

    func testWavFileReaderMatchesTheWholeFileRead() throws {
        let dir = tempDir("reader")
        defer { cleanup(dir) }
        let url = dir.appendingPathComponent("mix.f32.wav")
        let frames = interleave([sine(2000), sine(2000, freq: 330)])
        try PCMF32Wav.write(url: url, frames: frames, sampleRate: 44100, channels: 2)

        let whole = try PCMF32Wav.read(url: url)
        let reader = try WavFileReader(url: url)
        XCTAssertEqual(reader.sampleRate, 44100)
        XCTAssertEqual(reader.channels, 2)
        XCTAssertEqual(reader.totalFrames, 2000)
        for chunk in [1, 7, 512, 2000] {
            var assembled: [Float] = []
            var frame = 0
            while frame < reader.totalFrames {
                let count = min(chunk, reader.totalFrames - frame)
                assembled.append(contentsOf: try reader.read(startFrame: frame,
                                                             frameCount: count))
                frame += count
            }
            XCTAssertEqual(assembled, whole.frames, "reader chunk \(chunk) differs")
        }
    }

    // MARK: - 6) The tuning estimator's streamed input is bit-identical

    func testStreamingMono16kIsBitIdenticalToTheWholeFilePath() throws {
        let dir = tempDir("mono16k")
        defer { cleanup(dir) }
        let url = dir.appendingPathComponent("mix.f32.wav")
        let frames = interleave([sine(30000, freq: 440), sine(30000, freq: 554)])
        try PCMF32Wav.write(url: url, frames: frames, sampleRate: 44100, channels: 2)

        // REFERENCE: read whole → channel-mean fold → whole-buffer resample.
        let whole = try PCMF32Wav.read(url: url)
        var mono = [Float](repeating: 0, count: whole.frames.count / whole.channels)
        for (i, v) in whole.frames.enumerated() {
            mono[i / whole.channels] += v / Float(whole.channels)
        }
        let reference = AudioResampler.resample(samples: mono, sourceRate: whole.sampleRate,
                                                targetRate: SwiftF0Spec.sampleRate)

        // STREAMED: file-backed windows → fold → streaming resample.
        let streamed = try PCMF32Wav.mono16k(url: url)
        XCTAssertEqual(streamed.count, reference.count)
        XCTAssertEqual(streamed, reference, "the streamed 16 kHz mono differs")
    }

    /// The AC: the detuned fixtures still recover ±35c — through the STREAMED
    /// estimator input, and the value is the SAME as the whole-file path's.
    func testTuningEstimateUnchangedOnTheCommittedDetunedFixtures() throws {
        let dir = tempDir("tuning")
        defer { cleanup(dir) }
        for (name, expected) in [("mix44k_detuned_plus35.wav", 35), ("mix44k_detuned_minus35.wav", -35)] {
            let src = fixtureURL(name)
            let staged = dir.appendingPathComponent("staged-\(name).f32.wav")
            let decoded = try WavSourceDecoder().decodeToMix(source: src, workDir: dir)

            // OLD path (whole file → fold → estimate).
            let whole = try PCMF32Wav.read(url: decoded.url)
            var mono = [Float](repeating: 0, count: whole.frames.count / whole.channels)
            for (i, v) in whole.frames.enumerated() {
                mono[i / whole.channels] += v / Float(whole.channels)
            }
            let oldEstimate = TuningEstimator().estimate(samples: mono, sampleRate: whole.sampleRate)

            // NEW path (streamed 16 kHz → estimate).
            let x16 = try PCMF32Wav.mono16k(url: decoded.url)
            let newEstimate = TuningEstimator().estimate(samples16k: x16, frames: [])

            XCTAssertEqual(newEstimate, oldEstimate, "the estimate changed for \(name)")
            XCTAssertTrue((expected - 5...expected + 5).contains(newEstimate),
                          "\(name): expected ~\(expected)c, got \(newEstimate)c")
            _ = staged
        }
    }

    // MARK: - 7) The portable decoder streams too (no whole-file read)

    func testPortableDecoderStagesTheSameBytes() throws {
        let dir = tempDir("portable")
        defer { cleanup(dir) }
        let src = dir.appendingPathComponent("src.wav")
        let frames = interleave([sine(5000, freq: 440), sine(5000, freq: 554)])
        try PCMF32Wav.write(url: src, frames: frames, sampleRate: 44100, channels: 2)

        let decoded = try WavSourceDecoder().decodeToMix(source: src, workDir: dir)
        XCTAssertEqual(decoded.sampleRate, 44100)
        XCTAssertEqual(decoded.channels, 2)

        // The staged bytes must equal the whole-buffer reference.
        let reference = try WavSourceDecoder.normalizeAndStage(
            (samples: frames, sampleRate: 44100, channels: 2), workDir: dir)
        let a = try Data(contentsOf: decoded.url)
        let b = try Data(contentsOf: reference.url)
        XCTAssertEqual(a, b, "the streamed decoder staged different bytes")
    }

    // MARK: - Helpers

    /// Locate a committed fixture relative to this test file.
    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Spikes/Fixtures/\(name)")
    }
}
