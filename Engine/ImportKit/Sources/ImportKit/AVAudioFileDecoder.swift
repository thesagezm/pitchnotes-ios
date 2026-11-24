import Foundation
import AVFoundation
import EngineCore

// P-203 · Apple import decoder (PAUL lane). THIN on purpose: every policy
// decision (44.1 kHz target, mix channels ∈ {1,2}, >2ch pair-mean downmix,
// per-channel sinc resample, f32 staging WAV) lives in the portable EngineCore
// ImportPipeline/DecodePolicy (Linux-tested); this file only binds the seam:
//
//   AVAudioFile (native MP3/FLAC/ALAC/WAV decode — no ffmpeg on device, §6)
//   → deinterleaved Float32 buffer at the file's native rate/channels
//   → interleaved [Float] source-rate samples
//   → AudioDecoding.normalizeAndStageStreaming (SHARED path with
//     WavSourceDecoder).
//
// P-210 · THE DECODE IS STREAMED. The old path read the WHOLE file into one
// AVAudioPCMBuffer and then copied it into a whole-file interleaved array
// (≈ 85 MB each for a 4-minute stereo 44.1 kHz song), and the staging step
// copied it again three more times. Now the file is read in 8192-frame chunks
// and the staging mix is written as the chunks arrive — the song is never held
// in memory. The staged bytes are IDENTICAL to the whole-buffer path's
// (asserted in the Linux EngineCore tests; the macOS ImportKit tests prove
// the seam contract for all four container formats).
//
// THE ALAC LESSON APPLIES HERE TOO: `AVAudioFile.read(into:frameCount:)`
// THROWS when the source has fewer frames left than the requested count — so
// this decoder asks for EXACTLY the frames that remain (min(chunk, remaining)),
// never a full chunk. That is what killed the ALAC encoder until it was
// root-caused (P-204).
//
// Lossless containers (WAV/FLAC/ALAC) decode bit-identically here and in the
// ffmpeg reference (macOS ImportKitTests prove it against the committed
// fixtures); MP3 is decoder-dependent (CoreAudio vs ffmpeg) — tolerance-based
// comparison, documented honestly in the tests.

public struct AVAudioFileDecoder: AudioDecoding {
    /// The decode chunk (frames). Small enough to keep the transient memory
    /// tiny, large enough not to thrash the decoder.
    public static let chunkFrames = 8192

    public init() {}

    public func decodeToMix(source: URL, workDir: URL) throws -> DecodedAudio {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw EngineError.importFailed("input file does not exist at \(source.path)")
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: source)
        } catch {
            // Undecodable container/corrupt file → the seam's documented error.
            throw EngineError.unsupportedFormat(
                "AVAudioFile cannot open \(source.lastPathComponent): \(error.localizedDescription)")
        }
        let format = file.processingFormat // Float32, file's native rate, non-interleaved
        let channels = Int(format.channelCount)
        let sampleRate = Int(format.sampleRate)
        let totalFrames = Int(file.length)
        guard totalFrames > 0, channels >= 1 else {
            throw EngineError.unsupportedFormat(
                "empty decode (\(totalFrames) frames, \(channels) ch) for \(source.lastPathComponent)")
        }

        // The chunked decode: each chunk is deinterleaved and handed to the
        // streaming stager, which normalizes and writes it as it goes.
        var remaining = totalFrames
        return try Self.normalizeAndStageStreaming(
            sourceSampleRate: sampleRate,
            sourceChannels: channels,
            workDir: workDir) {
                guard remaining > 0 else { return nil }
                // EXACTLY the frames that remain — never a full chunk.
                let want = min(Self.chunkFrames, remaining)
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: AVAudioFrameCount(want)) else {
                    throw EngineError.unsupportedFormat(
                        "cannot allocate a \(want)-frame decode buffer for \(source.lastPathComponent)")
                }
                do {
                    try file.read(into: buffer, frameCount: AVAudioFrameCount(want))
                } catch {
                    throw EngineError.unsupportedFormat(
                        "decode failed for \(source.lastPathComponent): \(error.localizedDescription)")
                }
                let frames = Int(buffer.frameLength)
                guard frames > 0 else { return nil }
                guard let planes = buffer.floatChannelData else {
                    throw EngineError.unsupportedFormat(
                        "non-float decode format for \(source.lastPathComponent)")
                }
                // Deinterleaved channel planes → interleaved source-rate samples.
                var interleaved = [Float](repeating: 0, count: frames * channels)
                for c in 0..<channels {
                    let plane = planes[c]
                    for f in 0..<frames {
                        interleaved[f * channels + c] = plane[f]
                    }
                }
                remaining -= frames
                return interleaved
            }
    }
}
