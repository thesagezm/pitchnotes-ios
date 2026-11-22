import XCTest
import Foundation
import EngineCore
@testable import ImportKit

// P-203 · macOS CI proof of the AVAudioFileDecoder seam (X-204 runs
// `cd Engine/ImportKit && swift test` on macOS). The decoder is Apple-only
// (AVFoundation), so Linux never runs these; the portable decode core is
// Linux-proven in EngineCore (ImportDecodeTests).
//
// Comparison contract vs the ffmpeg REFERENCE (CI macOS runners ship ffmpeg;
// if it is ever missing the comparison tests SKIP with a loud note — honest
// degradation, never a fake pass):
//   - WAV / FLAC / ALAC are LOSSLESS: AVAudioFile decode must be BIT-IDENTICAL
//     to ffmpeg's decode (Float32 elementwise bit-pattern equality on the
//     staged 44.1 kHz mono mix; source rate = 44.1 kHz → passthrough, so the
//     staging samples ARE the decoded source samples).
//   - MP3 is LOSSY with DIFFERENT decoders (CoreAudio vs ffmpeg): tolerance
//     compare (best-offset alignment ±2048 frames, max |Δ| < 0.02 on the
//     overlap) — different decoders legitimately differ sample-by-sample.
//   - The 48 kHz stereo fixture exercises the shared sinc resample + D-8
//     channel-preserving staging structurally (count/channels/energy).

final class ImportKitTests: XCTestCase {

    private func tempDir(_ name: String) -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("importkit-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Locate a committed fixture relative to this test file (repo-root relative;
    /// same pattern as EngineCoreTests — requires the full repo checkout).
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ImportKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ImportKit
            .deletingLastPathComponent() // Engine
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Tests/Spikes/Fixtures/\(name)")
    }

    /// Locate ffmpeg (then ffprobe alongside it): standard runner + brew paths
    /// first, then PATH. Returns nil when unavailable (tests SKIP honestly).
    private func locateFFmpeg() -> URL? {
        let candidates = ["/usr/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        for p in candidates where FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathEnv.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("ffmpeg")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Run a tool with the given args, return (exitStatus, stdout).
    private func runTool(_ tool: URL, _ args: [String]) throws -> (Int32, Data) {
        let proc = Process()
        proc.executableURL = tool
        proc.arguments = args
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, data)
    }

    /// ffmpeg reference decode → interleaved [Float] at the fixture's native
    /// rate/channels (f32le on stdout). Returns nil if ffmpeg is unavailable.
    private func ffmpegDecode(_ fixture: URL) throws -> (samples: [Float], sampleRate: Int, channels: Int)? {
        guard let ffmpeg = locateFFmpeg() else { return nil }
        let probe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        guard FileManager.default.fileExists(atPath: probe.path) else { return nil }

        let (status, data) = try runTool(ffmpeg, ["-nostdin", "-v", "error", "-i", fixture.path,
                                                  "-f", "f32le", "-acodec", "pcm_f32le", "pipe:1"])
        guard status == 0, !data.isEmpty else {
            XCTFail("ffmpeg reference decode failed for \(fixture.lastPathComponent)")
            return nil
        }
        let (probeStatus, probeData) = try runTool(
            probe, ["-v", "error", "-select_streams", "a:0",
                    "-show_entries", "stream=sample_rate,channels", "-of", "csv=p=0", fixture.path])
        guard probeStatus == 0 else {
            XCTFail("ffprobe failed for \(fixture.lastPathComponent)")
            return nil
        }
        let nums = (String(data: probeData, encoding: .utf8) ?? "")
            .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard nums.count >= 2, nums[0] > 0, nums[1] >= 1 else {
            XCTFail("ffprobe output unusable for \(fixture.lastPathComponent)")
            return nil
        }
        let floats = data.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self)) }
        return (floats, nums[0], nums[1])
    }

    private func stagedSamples(_ mix: DecodedAudio) throws -> (samples: [Float], sampleRate: Int, channels: Int) {
        // PCMF32Wav.read labels its first element `frames`; this helper's
        // contract calls it `samples` (the ffmpeg reference's label) — remap
        // explicitly (a bare `return try PCMF32Wav.read(...)` does not compile:
        // tuple labels are part of the type).
        let staged = try PCMF32Wav.read(url: mix.url)
        return (samples: staged.frames, sampleRate: staged.sampleRate, channels: staged.channels)
    }

    /// Bit-identity of a lossless container's staged mono mix vs ffmpeg's
    /// decode. Source fixtures are 44.1 kHz mono → staging passthrough, so the
    /// staged samples ARE the decoded samples.
    private func assertLosslessBitIdentical(fixtureName: String, file: StaticString = #filePath, line: UInt = #line) throws {
        guard let ref = try ffmpegDecode(fixture(fixtureName)) else {
            throw XCTSkip("ffmpeg/ffprobe not available on this runner — lossless bit-identity unproven (honest skip)")
        }
        let dir = tempDir(fixtureName)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mix = try AVAudioFileDecoder().decodeToMix(source: fixture(fixtureName), workDir: dir)
        let (ours, sr, ch) = try stagedSamples(mix)

        XCTAssertEqual(sr, ref.sampleRate, file: file, line: line)
        XCTAssertEqual(ch, ref.channels, file: file, line: line)
        XCTAssertEqual(ours.count, ref.samples.count,
                       "\(fixtureName): frame count mismatch (AVAudioFile \(ours.count) vs ffmpeg \(ref.samples.count))",
                       file: file, line: line)
        let n = min(ours.count, ref.samples.count)
        // BIT-IDENTICAL: every sample's bit pattern must match (lossless both sides).
        var firstDiff: Int?
        for i in 0..<n where ours[i].bitPattern != ref.samples[i].bitPattern {
            firstDiff = i
            break
        }
        if let i = firstDiff {
            XCTFail("\(fixtureName): NOT bit-identical to ffmpeg decode at frame \(i) " +
                    "(ours bitPattern \(ours[i].bitPattern) vs ref \(ref.samples[i].bitPattern))",
                    file: file, line: line)
        }
    }

    // MARK: - Lossless bit-identity

    func testWavDecodeBitIdenticalToFFmpeg() throws {
        try assertLosslessBitIdentical(fixtureName: "mix44k_short.wav")
    }

    func testFLACDecodeBitIdenticalToFFmpeg() throws {
        try assertLosslessBitIdentical(fixtureName: "mix44k_short.flac")
    }

    func testALACDecodeBitIdenticalToFFmpeg() throws {
        try assertLosslessBitIdentical(fixtureName: "mix44k_short_alac.m4a")
    }

    // MARK: - MP3 (lossy, different decoders → tolerance)

    func testMP3DecodeToleranceVsFFmpeg() throws {
        guard let ref = try ffmpegDecode(fixture("mix44k_short.mp3")) else {
            throw XCTSkip("ffmpeg/ffprobe not available on this runner — MP3 tolerance unproven (honest skip)")
        }
        let dir = tempDir("mp3")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mix = try AVAudioFileDecoder().decodeToMix(source: fixture("mix44k_short.mp3"), workDir: dir)
        let (ours, sr, ch) = try stagedSamples(mix)
        XCTAssertEqual(sr, ref.sampleRate)
        XCTAssertEqual(ch, ref.channels)
        XCTAssertTrue(ours.count > 0 && ref.samples.count > 0)

        // Best-offset alignment within ±2048 frames (encoder delay/padding
        // differences between decoders), then max deviation on the overlap.
        let search = 2048
        let a = ours, b = ref.samples
        var bestOffset = 0
        var bestEnergy = Double.greatestFiniteMagnitude
        for off in stride(from: -search, through: search, by: 64) {
            let lo = max(0, off)
            let hi = min(a.count, b.count + off)
            guard hi - lo > 1000 else { continue }
            var energy = 0.0
            var i = lo, k = 0
            while i < hi, k < 20_000 {
                let d = Double(a[i] - b[i - off])
                energy += d * d
                i += 16; k += 1 // stride-sample: alignment is coarse
            }
            if energy < bestEnergy { bestEnergy = energy; bestOffset = off }
        }
        // Exact deviation on the aligned overlap.
        let lo = max(0, bestOffset)
        let hi = min(a.count, b.count + bestOffset)
        XCTAssertGreaterThan(hi - lo, Int(2.0 * Double(ref.sampleRate)),
                             "aligned overlap too small (\(hi - lo) frames)")
        var maxDiff: Float = 0
        var i = lo
        while i < hi {
            maxDiff = max(maxDiff, abs(a[i] - b[i - bestOffset]))
            i += 1
        }
        XCTAssertLessThan(maxDiff, 0.02,
                          "MP3 decoders diverge more than tolerance (max |Δ| \(maxDiff), offset \(bestOffset))")
    }

    // MARK: - 48 kHz stereo fixture (shared sinc resample + channel policy)

    func testDecode48kStereoStages44k1Stereo() throws {
        let dir = tempDir("48k")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mix = try AVAudioFileDecoder().decodeToMix(source: fixture("mix48k_stereo.wav"), workDir: dir)
        XCTAssertEqual(mix.sampleRate, 44100)
        XCTAssertEqual(mix.channels, 2, "D-8: stereo mix stays channel-preserving")
        XCTAssertEqual(mix.duration_s, 2.5, accuracy: 1 / 44100.0 + 1e-3)
        let (frames, sr, ch) = try PCMF32Wav.read(url: mix.url)
        XCTAssertEqual(sr, 44100); XCTAssertEqual(ch, 2)
        XCTAssertTrue(frames.count > 2 * 44100 * 2 && frames.count < 2 * 44100 * 3)
        // Both channels carry energy (L leads melody, R leads chord by design).
        let l = stride(from: 0, to: frames.count, by: 2).map { abs(frames[$0]) }.reduce(0, max)
        let r = stride(from: 1, to: frames.count, by: 2).map { abs(frames[$0]) }.reduce(0, max)
        XCTAssertGreaterThan(l, 0.4); XCTAssertGreaterThan(r, 0.4)
    }

    // MARK: - Error contract

    func testUnsupportedContainerThrowsUnsupportedFormat() throws {
        let dir = tempDir("bad")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("song.txt")
        try Data("definitely not audio".utf8).write(to: src)
        do {
            _ = try AVAudioFileDecoder().decodeToMix(source: src, workDir: dir)
            XCTFail("garbage container must throw")
        } catch let e as EngineError {
            guard case .unsupportedFormat = e else { XCTFail("wrong error: \(e)"); return }
        }
    }

    func testMissingFileThrowsImportFailed() throws {
        let dir = tempDir("missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            _ = try AVAudioFileDecoder().decodeToMix(source: dir.appendingPathComponent("nope.mp3"), workDir: dir)
            XCTFail("missing file must throw")
        } catch let e as EngineError {
            guard case .importFailed = e else { XCTFail("wrong error: \(e)"); return }
        }
    }
}
