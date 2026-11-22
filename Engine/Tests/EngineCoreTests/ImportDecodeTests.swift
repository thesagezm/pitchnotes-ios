import Foundation
import XCTest
@testable import EngineCore

// P-203: import/decode core — D-8 policies, channel-preserving staging I/O,
// pipeline orchestration (hash → decode → manifest v1.0), C-8 progress and
// cancellation. The WAV decoder is the portable AudioDecoding conformer; the
// Apple AVAudioFileDecoder (ImportKit, CI-proven on macOS) implements the same
// seam for MP3/FLAC/ALAC.

final class ImportDecodeTests: XCTestCase {

    private func tempDir(_ name: String) -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("p203-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func cleanup(_ dirs: URL...) {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
    }

    /// Minimal PCM16 WAV writer (channel-preserving; header word-aligned).
    private func writePcm16Wav(url: URL, frames: [Float], sampleRate: Int, channels: Int) throws {
        var data = Data()
        func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        // Payload first (sizes need its length); then the header; then payload.
        var payload = Data()
        for f in frames {
            let v = Int16(max(-32768, min(32767, Int(f * 32767.0)))).littleEndian
            withUnsafeBytes(of: v) { payload.append(contentsOf: $0) }
        }
        ascii("RIFF"); u32(UInt32(36 + payload.count)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        ascii("data"); u32(UInt32(payload.count))
        data.append(payload)
        try data.write(to: url)
    }

    private func sine(_ n: Int, freq: Double = 440.0, sr: Int = 44100, phase: Double = 0) -> [Float] {
        let twoPiFreq: Double = 2.0 * Double.pi * freq
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t: Double = twoPiFreq * Double(i) / Double(sr) + phase
            out[i] = Float(Foundation.sin(t))
        }
        return out
    }

    private func twoStemParts() -> [PartInfo] {
        [PartInfo(part: .vocals, stemFile: "stems/VOCALS.m4a", channels: 1, noteConfidence: 0.0),
         PartInfo(part: .instrumental, stemFile: "stems/INSTRUMENTAL.m4a", channels: 2, noteConfidence: 0.0)]
    }

    // MARK: - DecodePolicy (D-8)

    func testDecodePolicyMixChannels() throws {
        XCTAssertEqual(try DecodePolicy.mixChannels(sourceChannels: 1), 1)
        XCTAssertEqual(try DecodePolicy.mixChannels(sourceChannels: 2), 2)
        XCTAssertEqual(try DecodePolicy.mixChannels(sourceChannels: 3), 2)
        XCTAssertEqual(try DecodePolicy.mixChannels(sourceChannels: 6), 2)
        XCTAssertThrowsError(try DecodePolicy.mixChannels(sourceChannels: 0))
    }

    func testQuadDownmixPairsToStereoMeans() throws {
        // channels: [L1 R1 L2 R2] per frame → L = mean(L1, L2), R = mean(R1, R2).
        let src: [Float] = [0.2, -0.4, 0.6, 0.8]
        let (out, ch) = try DecodePolicy.applyMixChannelPolicy(interleaved: src, sourceChannels: 4)
        XCTAssertEqual(ch, 2)
        let expected: [Float] = [0.4, 0.2]
        XCTAssertEqual(out.count, expected.count)
        let acc = Float(1e-6)
        for (i, v) in expected.enumerated() {
            XCTAssertEqual(out[i], v, accuracy: acc)
        }
    }

    // MARK: - Float32 staging WAV

    func testF32WavRoundTripStereoLossless() throws {
        let dir = tempDir("f32rt")
        defer { cleanup(dir) }
        let url = dir.appendingPathComponent("mix.f32.wav")
        var frames = [Float]()
        frames.reserveCapacity(1000)
        for f in 0..<500 {
            let a: Double = 2.0 * Double.pi * 220.0 * Double(f) / 44100.0
            let b: Double = 2.0 * Double.pi * 330.0 * Double(f) / 44100.0
            frames.append(Float(Foundation.sin(a)))
            frames.append(Float(Foundation.cos(b)))
        }
        try PCMF32Wav.write(url: url, frames: frames, sampleRate: 44100, channels: 2)
        let (back, sr, ch) = try PCMF32Wav.read(url: url)
        XCTAssertEqual(sr, 44100)
        XCTAssertEqual(ch, 2)
        XCTAssertEqual(back, frames) // float32 → float32 must be bit-exact
    }

    func testF32WavRejectsGarbage() throws {
        let dir = tempDir("f32bad")
        defer { cleanup(dir) }
        let url = dir.appendingPathComponent("garbage.wav")
        try Data("definitely not a wav".utf8).write(to: url)
        XCTAssertThrowsError(try PCMF32Wav.read(url: url))
    }

    // MARK: - WavSourceDecoder (AudioDecoding conformer)

    func testWavDecoderPassthrough44k1Stereo() throws {
        let dir = tempDir("pass")
        defer { cleanup(dir) }
        let src = dir.appendingPathComponent("src.wav")
        let work = dir.appendingPathComponent("work")
        let n = 4410 // 0.1 s
        let l = sine(n, freq: 440)
        let r = sine(n, freq: 550, phase: 1.1)
        let interleaved = zip(l, r).flatMap { [$0, $1] }
        try writePcm16Wav(url: src, frames: interleaved, sampleRate: 44100, channels: 2)

        let mix = try WavSourceDecoder().decodeToMix(source: src, workDir: work)
        XCTAssertEqual(mix.sampleRate, 44100)
        XCTAssertEqual(mix.channels, 2)
        XCTAssertEqual(mix.duration_s, Double(n) / 44100.0, accuracy: 1e-9)
        // PCM16 decode path is exact vs the QUANTIZED expectation (the helper
        // truncates to Int16 full scale 32767): Float(Int16(trunc(f*32767)))/32768.
        let (back, sr, ch) = try PCMF32Wav.read(url: mix.url)
        XCTAssertEqual(sr, 44100); XCTAssertEqual(ch, 2)
        XCTAssertEqual(back.count, n * 2)
        for (i, f) in interleaved.enumerated() {
            let q = Float(Int16(max(-32768, min(32767, Int(f * 32767.0))))) / 32768.0
            XCTAssertEqual(back[i], q, accuracy: Float(1e-9), "frame \(i)")
        }
    }

    func testWavDecoderResamples48kTo44k1() throws {
        let dir = tempDir("resample")
        defer { cleanup(dir) }
        let src = dir.appendingPathComponent("src48.wav")
        let work = dir.appendingPathComponent("work")
        let n = 9600 // 0.2 s at 48 kHz
        try writePcm16Wav(url: src, frames: sine(n, freq: 440, sr: 48000), sampleRate: 48000, channels: 1)

        let mix = try WavSourceDecoder().decodeToMix(source: src, workDir: work)
        XCTAssertEqual(mix.sampleRate, 44100)
        XCTAssertEqual(mix.channels, 1)
        XCTAssertEqual(mix.duration_s, 0.2, accuracy: 1 / 44100.0 + 1e-3) // ±1 frame, sinc rounding
        let (back, sr, ch) = try PCMF32Wav.read(url: mix.url)
        XCTAssertEqual(sr, 44100); XCTAssertEqual(ch, 1)
        XCTAssertTrue(back.count > 8000 && back.count < 9200)
        // Sinc resampler preserves the tone: dominant frequency stays 440 Hz.
        XCTAssertTrue(maxAbs(back) > 0.5, "resampled tone must retain amplitude")
    }

    func testWavDecoderRejectsNonWav() throws {
        let dir = tempDir("nonwav")
        defer { cleanup(dir) }
        let src = dir.appendingPathComponent("src.bin")
        try Data("not audio at all".utf8).write(to: src)
        XCTAssertThrowsError(try WavSourceDecoder().decodeToMix(source: src, workDir: dir))
    }

    func testWavDecoderMissingFileThrowsImportFailed() throws {
        let dir = tempDir("missing")
        defer { cleanup(dir) }
        XCTAssertThrowsError(try WavSourceDecoder()
            .decodeToMix(source: dir.appendingPathComponent("nope.wav"), workDir: dir))
    }

    // MARK: - ImportPipeline end-to-end

    func testPipelineEndToEndManifestV1Valid() async throws {
        let dir = tempDir("e2e")
        defer { cleanup(dir) }
        let src = dir.appendingPathComponent("song.wav")
        let work = dir.appendingPathComponent("work")
        let n = 22050 // 0.5 s
        try writePcm16Wav(url: src, frames: sine(n), sampleRate: 44100, channels: 1)

        let recorder = ProgressRecorder()
        let emitter = ImportProgressEmitter()
        emitter.setHandler { p in
            if p.stage == .decoding { recorder.append(p.fraction) }
        }

        let result = try await ImportPipeline.run(
            source: src, title: "Fixture Song", workDir: work,
            hasher: nil, decoder: WavSourceDecoder(), emitter: emitter,
            tuningCents: 32, hasInstrumental: true,
            parts: twoStemParts(), meanNoteConfidence: 0.7)

        // Manifest v1.0 fields per C-2.1.
        XCTAssertEqual(result.manifest.contractVersion, "v1.0")
        XCTAssertEqual(result.manifest.sampleRate, 44100)
        XCTAssertEqual(result.manifest.channels, 1)
        XCTAssertEqual(result.manifest.tuning_cents, 32)
        XCTAssertTrue(result.manifest.hasInstrumental)
        XCTAssertEqual(result.manifest.id.count, 26)
        XCTAssertEqual(result.manifest.engineVersion, ImportPipeline.engineVersion)
        XCTAssertEqual(result.manifest.duration_s, 0.5, accuracy: 1e-9)
        // Hash = BLAKE3 of the ORIGINAL file bytes (pre-decode), stable.
        let direct = try Blake3FileHasher().hashFile(at: src)
        XCTAssertEqual(result.sourceHash.hex, direct.hex)
        XCTAssertEqual(result.manifest.sourceHash, direct)
        // Manifest validates against the frozen contract (V1–V15).
        let v = BundleValidator.validate(manifest: result.manifest)
        XCTAssertTrue(v.isValid, "violations: \(v.violations)")
        // Staged mix exists and matches the descriptor.
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.mix.url.path, isDirectory: &isDir))
        XCTAssertFalse(isDir.boolValue)
        // C-8 progress: monotonic, ends at 1.0.
        let stages = recorder.snapshot()
        XCTAssertTrue(zip(stages, stages.dropFirst()).allSatisfy { $0.0 <= $0.1 + 1e-9 },
                      "progress not monotonic: \(stages)")
        XCTAssertEqual(stages.last ?? 0, 1.0, accuracy: 1e-9)
    }

    func testPipelineHashStableAcrossRunsIdDiffers() async throws {
        let dir = tempDir("stable")
        defer { cleanup(dir) }
        let src = dir.appendingPathComponent("song.wav")
        try writePcm16Wav(url: src, frames: sine(4410), sampleRate: 44100, channels: 1)
        let r1 = try await ImportPipeline.run(source: src, title: "t", workDir: dir.appendingPathComponent("w1"),
                                              hasher: nil, decoder: WavSourceDecoder(), emitter: nil,
                                              parts: twoStemParts())
        let r2 = try await ImportPipeline.run(source: src, title: "t", workDir: dir.appendingPathComponent("w2"),
                                              hasher: nil, decoder: WavSourceDecoder(), emitter: nil,
                                              parts: twoStemParts())
        XCTAssertEqual(r1.sourceHash, r2.sourceHash, "same bytes → same sourceHash")
        XCTAssertNotEqual(r1.manifest.id, r2.manifest.id, "each import gets its own ULID")
    }

    func testPipelineCancellationAfterStagingCleansUp() async throws {
        let dir = tempDir("cancel")
        defer { cleanup(dir) }
        let src = dir.appendingPathComponent("song.wav")
        let work = dir.appendingPathComponent("work")
        try writePcm16Wav(url: src, frames: sine(4410), sampleRate: 44100, channels: 1)

        // Decoder that stages the real mix, then cancels the current task so
        // the pipeline's post-decode cancellation check fires.
        struct CancelAfterStage: AudioDecoding {
            let work: URL
            func decodeToMix(source: URL, workDir: URL) throws -> DecodedAudio {
                let mix = try WavSourceDecoder().decodeToMix(source: source, workDir: workDir)
                XCTAssertTrue(FileManager.default.fileExists(atPath: mix.url.path))
                withUnsafeCurrentTask { $0?.cancel() }
                return mix
            }
        }

        do {
            _ = try await ImportPipeline.run(source: src, title: "t", workDir: work,
                                             hasher: nil, decoder: CancelAfterStage(work: work),
                                             emitter: nil, parts: twoStemParts())
            XCTFail("pipeline must rethrow cancellation")
        } catch is CancellationError {
            // expected
        }
        // Staged mix is gone (C-2.2: cancelled job leaves no residue).
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "staging not cleaned: \(leftovers)")
    }

    // MARK: - Committed fixtures (Tests/Spikes/Fixtures, P-001 sha-pinned)

    /// Locate a committed fixture relative to this test file (works on Linux +
    /// macOS CI; requires the FULL-repo mount for the docker loop — same
    /// pattern as SwiftF0CoreTests).
    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // EngineCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Engine
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Tests/Spikes/Fixtures/\(name)")
    }

    /// The committed 48 kHz STEREO fixture goes through the full portable
    /// decode path: 48k→44.1k sinc resample + D-8 channel-preserving staging
    /// (mix stays 2 ch), BLAKE3 over the ORIGINAL committed bytes, manifest
    /// v1.0 valid per V1–V15.
    func testPipelineCommittedMix48kStereoFixture() async throws {
        let src = fixtureURL("mix48k_stereo.wav")
        let dir = tempDir("fixture48")
        defer { cleanup(dir) }

        let result = try await ImportPipeline.run(
            source: src, title: "Fixture 48k Stereo", workDir: dir,
            hasher: nil, decoder: WavSourceDecoder(), emitter: nil,
            parts: twoStemParts())

        XCTAssertEqual(result.manifest.sampleRate, 44100)
        XCTAssertEqual(result.manifest.channels, 2)
        XCTAssertEqual(result.manifest.duration_s, 2.5, accuracy: 1 / 44100.0 + 1e-3)
        XCTAssertEqual(result.manifest.contractVersion, "v1.0")
        let direct = try Blake3FileHasher().hashFile(at: src)
        XCTAssertEqual(result.sourceHash.hex, direct.hex)
        let v = BundleValidator.validate(manifest: result.manifest)
        XCTAssertTrue(v.isValid, "violations: \(v.violations)")
        // Staged mix: 44.1 kHz stereo, plausible sample count (2.5 s ± resampler).
        let (frames, sr, ch) = try PCMF32Wav.read(url: result.mix.url)
        XCTAssertEqual(sr, 44100); XCTAssertEqual(ch, 2)
        XCTAssertTrue(frames.count > 2 * 44100 * 2 && frames.count < 2 * 44100 * 3,
                      "unexpected resampled length \(frames.count)")
        // Energy survived: both channels carry the mixture.
        XCTAssertTrue(maxAbs(frames) > 0.5)
    }

    /// The canonical mono 44.1k mixture fixture passes through unchanged
    /// (passthrough decode, hash pin).
    func testPipelineCommittedMix44kFixture() async throws {
        let src = fixtureURL("mix44k_short.wav")
        let dir = tempDir("fixture44")
        defer { cleanup(dir) }

        let result = try await ImportPipeline.run(
            source: src, title: "Fixture 44k Mono", workDir: dir,
            hasher: nil, decoder: WavSourceDecoder(), emitter: nil,
            parts: twoStemParts())

        XCTAssertEqual(result.manifest.sampleRate, 44100)
        XCTAssertEqual(result.manifest.channels, 1)
        XCTAssertEqual(result.manifest.duration_s, 2.5, accuracy: 1e-9)
        let direct = try Blake3FileHasher().hashFile(at: src)
        XCTAssertEqual(result.sourceHash.hex, direct.hex)
        XCTAssertTrue(BundleValidator.validate(manifest: result.manifest).isValid)
    }

    // MARK: - Manifest builder

    func testManifestBuilderTuningClamp() throws {
        func manifest(_ cents: Int) -> SongManifest {
            ImportManifestBuilder.build(
                mix: DecodedAudio(url: URL(fileURLWithPath: "/tmp/x.wav"), sampleRate: 44100,
                                  channels: 2, duration_s: 1.0),
                title: "t", sourceHash: SourceHash(hex: String(repeating: "a", count: 64)),
                tuningCents: cents, hasInstrumental: true, parts: [])
        }
        XCTAssertEqual(manifest(35).tuning_cents, 35)
        XCTAssertEqual(manifest(90).tuning_cents, 50)
        XCTAssertEqual(manifest(-90).tuning_cents, -50)
        XCTAssertEqual(manifest(0).tuning_cents, 0)
    }

    func testPipelineRejectsMissingSource() async throws {
        let dir = tempDir("nosrc")
        defer { cleanup(dir) }
        do {
            _ = try await ImportPipeline.run(source: dir.appendingPathComponent("gone.wav"),
                                             title: "t", workDir: dir, hasher: nil,
                                             decoder: WavSourceDecoder(), emitter: nil)
            XCTFail("missing source must throw")
        } catch let e as EngineError {
            if case .importFailed = e {} else { XCTFail("wrong error: \(e)") }
        }
    }

    private func maxAbs(_ x: [Float]) -> Float {
        x.reduce(0) { max($0, abs($1)) }
    }

    /// Lock-guarded fraction sink (the C-8 handler fires on an arbitrary thread).
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []
        func append(_ v: Double) {
            lock.lock(); values.append(v); lock.unlock()
        }
        func snapshot() -> [Double] {
            lock.lock(); defer { lock.unlock() }
            return values
        }
    }
}
