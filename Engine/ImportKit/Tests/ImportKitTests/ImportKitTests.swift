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
//   - MP3 is LOSSY and the two decoders differ in TWO ways: (a) different
//     synthesis ⇒ sample-by-sample differences, compared by SNR after a
//     step-1 integer alignment; (b) CoreAudio does NOT apply the LAME
//     gapless tag, so its decode keeps the ~1105-sample encoder delay and
//     the trailing padding (111744 frames for the 2.5 s fixture) while
//     ffmpeg returns the trimmed 110250. The alignment offset therefore
//     STARTS at the encoder delay; the extra frames are codec padding, and
//     the MP3 import leg asserts the count is a whole number of MPEG
//     frames (1152 samples). The source-WAV reference leg proves the MP3
//     decode agrees with the source WITHOUT any ffmpeg dependency.
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

    /// Best integer alignment of `ours` (the LONGER signal) against `ref`:
    /// returns the offset `o` minimising the squared difference of
    /// `ours[i]` vs `ref[i - o]`. Searched at step 1 (a coarse grid picks a
    /// misalignment of tens of frames, which on tonal content produces a
    /// huge amplitude error and a false "decoder divergence").
    ///
    /// The offset is non-negative because CoreAudio's MP3 decoder does NOT
    /// apply LAME gapless trimming: the decoded signal starts with the
    /// encoder delay (~1105 samples) that ffmpeg trims away.
    private func bestAlignmentOffset(_ ours: [Float], _ ref: [Float],
                                     maxOffset: Int) -> (offset: Int, energy: Double) {
        var bestOffset = 0
        var bestEnergy = Double.greatestFiniteMagnitude
        for off in 0...max(0, maxOffset) {
            let lo = off
            let hi = min(ours.count, ref.count + off)
            guard hi - lo > 1000 else { continue }
            var energy = 0.0
            var i = lo
            while i < hi {
                let d = Double(ours[i] - ref[i - off])
                energy += d * d
                i += 16 // stride-sample: coarse but offset-independent
            }
            if energy < bestEnergy { bestEnergy = energy; bestOffset = off }
        }
        return (bestOffset, bestEnergy)
    }

    /// SNR (dB) of `ours` against `ref` over the aligned overlap
    /// (`ours[i]` vs `ref[i - offset]`), plus the peak absolute deviation.
    private func alignmentStats(_ ours: [Float], _ ref: [Float], offset: Int)
        -> (snrDB: Double, maxAbsDiff: Float, frames: Int) {
        let lo = offset
        let hi = min(ours.count, ref.count + offset)
        guard hi > lo else { return (-.infinity, .infinity, 0) }
        var signalEnergy = 0.0
        var errorEnergy = 0.0
        var maxDiff: Float = 0
        var i = lo
        while i < hi {
            let reference = ref[i - offset]
            let d = Double(ours[i] - reference)
            errorEnergy += d * d
            signalEnergy += Double(reference) * Double(reference)
            maxDiff = max(maxDiff, abs(ours[i] - reference))
            i += 1
        }
        let snr = errorEnergy > 0 ? 10 * log10(signalEnergy / errorEnergy) : .infinity
        return (snr, maxDiff, hi - lo)
    }

    /// The accepted encoder-delay window, in samples at 44.1 kHz.
    ///
    /// The MP3 gapless delay accounting is 1105 samples = 576 (encoder side)
    /// + 529 (decoder side), and the two decoders we compare against apply
    /// DIFFERENT parts of it:
    ///   - ffmpeg's RAW decode (Info/LAME tag neutralised, verified locally):
    ///     the whole 1105 → aligns with the source WAV at offset 1105.
    ///   - CoreAudio/AVAudioFile (measured on the macOS runner, run
    ///     45078702137): it applies the 529-sample decoder-side delay but NOT
    ///     the LAME gapless trim → it aligns at 1105 − 529 = **576**.
    /// The window brackets both conventions. The SNR assertion below is the
    /// real guarantee (a wrong offset scores ≈ −2 dB, not 26 dB); the window
    /// is a sanity check that the delay stays in a plausible range.
    private static let mp3DelayWindow = 512...1216

    private func stagedSamples(_ mix: DecodedAudio) throws -> (samples: [Float], sampleRate: Int, channels: Int) {
        // PCMF32Wav.read labels its first element `frames`; this helper's
        // contract calls it `samples` (the ffmpeg reference's label) — remap
        // explicitly (a bare `return try PCMF32Wav.read(...)` does not compile:
        // tuple labels are part of the type).
        let staged = try PCMF32Wav.read(url: mix.url)
        return (samples: staged.frames, sampleRate: staged.sampleRate, channels: staged.channels)
    }

    /// The P-203 acceptance leg: THE FORMAT IMPORTS. This assertion does NOT
    /// depend on ffmpeg — it proves that AVAudioFile decodes the container and
    /// that the staged mix is well-formed (rate/channels/duration/finite
    /// non-silent audio).
    ///
    /// It used to be folded into the ffmpeg comparison tests, which SKIP when
    /// ffmpeg is missing — and the macOS CI runner has NO ffmpeg, so the
    /// import leg never actually ran (the skip happened before the decode).
    /// The comparison is now a SEPARATE, additive test; the import itself is
    /// always proven.
    private func assertImports(fixtureName: String, frameTolerance: Int = 2,
                               expectFrameMultiple: Int? = nil,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let dir = tempDir(fixtureName)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mix = try AVAudioFileDecoder().decodeToMix(source: fixture(fixtureName), workDir: dir)

        XCTAssertEqual(mix.sampleRate, 44100, "\(fixtureName): D-8 sample rate", file: file, line: line)
        XCTAssertEqual(mix.channels, 1, "\(fixtureName): source fixture is mono", file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mix.url.path),
                      "\(fixtureName): staged mix missing", file: file, line: line)
        XCTAssertEqual(mix.duration_s, 2.5,
                       accuracy: max(1 / 44100.0 + 1e-3, Double(frameTolerance) / 44100.0),
                       "\(fixtureName): staged duration", file: file, line: line)

        let (samples, sr, ch) = try stagedSamples(mix)
        XCTAssertEqual(sr, 44100, file: file, line: line)
        XCTAssertEqual(ch, 1, file: file, line: line)
        XCTAssertEqual(samples.count, Int(2.5 * 44100), accuracy: frameTolerance,
                       "\(fixtureName): staged frame count", file: file, line: line)
        if let multiple = expectFrameMultiple {
            XCTAssertEqual(samples.count % multiple, 0,
                           "\(fixtureName): staged frame count \(samples.count) is not a whole number of " +
                           "\(multiple)-sample frames", file: file, line: line)
        }
        for (i, v) in samples.enumerated() where !v.isFinite {
            XCTFail("\(fixtureName): non-finite sample at \(i)", file: file, line: line)
            break
        }
        // The fixture carries a real signal (melody + chord) — a decode that
        // silently yields silence would otherwise pass the checks above.
        let peak = samples.map { abs($0) }.reduce(0, max)
        XCTAssertGreaterThan(peak, 0.3, "\(fixtureName): decoded audio is silent (peak \(peak))",
                             file: file, line: line)
    }

    /// Bit-identity of a lossless container's staged mono mix vs ffmpeg's
    /// decode. Source fixtures are 44.1 kHz mono → staging passthrough, so the
    /// staged samples ARE the decoded samples.
    ///
    /// SKIPS when the runner has no ffmpeg — the import leg is proven by
    /// `assertImports` regardless; this is the ADDITIVE cross-decoder check.
    private func assertLosslessBitIdentical(fixtureName: String, file: StaticString = #filePath, line: UInt = #line) throws {
        guard let ref = try ffmpegDecode(fixture(fixtureName)) else {
            throw XCTSkip("ffmpeg/ffprobe not available on this runner — lossless bit-identity unproven (honest skip; the IMPORT leg is proven separately)")
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

    // MARK: - The P-203 acceptance leg: each committed format fixture IMPORTS
    // (no ffmpeg dependency — these always run on the macOS runner).

    func testWavFixtureImports() throws {
        try assertImports(fixtureName: "mix44k_short.wav")
    }

    func testMP3FixtureImports() throws {
        // MP3 (lossy) carries the ENCODER's padding in CoreAudio's decode:
        // AVAudioFile does NOT apply LAME gapless trimming, so the decoded
        // length is the FULL encoded frame count — 97 MPEG frames × 1152
        // samples = 111744 frames for this 2.5 s source (i.e. +1494 frames
        // ≈ +33.9 ms: the ~1105-sample encoder delay plus the trailing
        // padding). ffmpeg, by contrast, DOES honour the LAME gapless tag and
        // returns exactly 110250 frames (verified locally). The tolerance
        // therefore covers two MPEG frames, and the frame count is asserted
        // to be a whole number of MPEG frames (which proves the extra frames
        // are codec padding, not duplicated source audio).
        try assertImports(fixtureName: "mix44k_short.mp3", frameTolerance: 2 * 1152,
                          expectFrameMultiple: 1152)
    }

    /// MP3 import quality, WITHOUT any ffmpeg dependency: the decoded MP3
    /// must agree with the committed SOURCE WAV once the encoder delay is
    /// removed. This is the ffmpeg-independent proof that the MP3 path
    /// actually decodes the song (not silence, not garbage) — measured
    /// locally against ffmpeg's decode of the same fixture: SNR 26.0 dB,
    /// max |Δ| 0.045 (128 kbps codec error).
    func testMP3DecodeMatchesSourceWithinCodecError() throws {
        let dir = tempDir("mp3-src")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mix = try AVAudioFileDecoder().decodeToMix(source: fixture("mix44k_short.mp3"), workDir: dir)
        let sourceDir = tempDir("wav-src")
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let sourceMix = try AVAudioFileDecoder().decodeToMix(source: fixture("mix44k_short.wav"),
                                                             workDir: sourceDir)
        let (ours, _, _) = try stagedSamples(mix)
        let (ref, _, _) = try stagedSamples(sourceMix)

        XCTAssertGreaterThan(ours.count, ref.count,
                             "CoreAudio is expected to keep the MP3 encoder delay (no LAME gapless trim)")
        let (offset, _) = bestAlignmentOffset(ours, ref, maxOffset: 2400)
        XCTAssertTrue(Self.mp3DelayWindow.contains(offset),
                      "expected the MP3 encoder delay at the head of the decode (CoreAudio ~576, ffmpeg ~1105), got \(offset)")
        let stats = alignmentStats(ours, ref, offset: offset)
        XCTAssertGreaterThan(stats.frames, Int(2.0 * 44100), "aligned overlap too small")
        XCTAssertGreaterThan(stats.snrDB, 18.0,
                             "MP3 decode disagrees with the source WAV (SNR \(stats.snrDB) dB, " +
                             "max |Δ| \(stats.maxAbsDiff), offset \(offset))")
    }

    func testFLACFixtureImports() throws {
        try assertImports(fixtureName: "mix44k_short.flac")
    }

    func testALACFixtureImports() throws {
        try assertImports(fixtureName: "mix44k_short_alac.m4a")
    }

    // MARK: - Lossless bit-identity (additive cross-decoder check; skips
    // without ffmpeg — the import leg above is the ac)

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
            throw XCTSkip("ffmpeg/ffprobe not available on this runner — MP3 cross-decoder tolerance unproven " +
                          "(honest skip; the IMPORT leg and the source-WAV reference leg are proven without ffmpeg)")
        }
        let dir = tempDir("mp3")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mix = try AVAudioFileDecoder().decodeToMix(source: fixture("mix44k_short.mp3"), workDir: dir)
        let (ours, sr, ch) = try stagedSamples(mix)
        XCTAssertEqual(sr, ref.sampleRate)
        XCTAssertEqual(ch, ref.channels)
        XCTAssertTrue(ours.count > 0 && ref.samples.count > 0)

        // ffmpeg honours the LAME gapless tag (110250 frames for this
        // fixture); CoreAudio keeps the encoder delay + padding (111744).
        // Align at STEP 1 (a coarse grid leaves tens of frames of
        // misalignment, which reads as a huge amplitude "divergence" on
        // tonal content) and require the offset to land in the encoder-delay
        // window. Then compare the ALIGNED signals by SNR — two independent
        // lossy decoders of the same frames differ in their synthesis, so a
        // max-sample bound would be brittle; SNR is the meaningful measure.
        // Local reference (ffmpeg's decode vs the source WAV): 26.0 dB.
        XCTAssertGreaterThanOrEqual(ours.count, ref.samples.count,
                                    "expected CoreAudio's untrimmed decode to be at least as long as ffmpeg's")
        let (offset, _) = bestAlignmentOffset(ours, ref.samples, maxOffset: 2400)
        XCTAssertTrue(Self.mp3DelayWindow.contains(offset),
                      "expected the MP3 encoder delay at the head of the decode (CoreAudio ~576, ffmpeg ~1105), got \(offset)")
        let stats = alignmentStats(ours, ref.samples, offset: offset)
        XCTAssertGreaterThan(stats.frames, Int(2.0 * Double(ref.sampleRate)),
                             "aligned overlap too small (\(stats.frames) frames)")
        XCTAssertGreaterThan(stats.snrDB, 15.0,
                             "MP3 decoders diverge more than tolerance (SNR \(stats.snrDB) dB, " +
                             "max |Δ| \(stats.maxAbsDiff), offset \(offset))")
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
