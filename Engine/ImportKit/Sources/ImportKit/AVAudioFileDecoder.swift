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
//   → AudioDecoding.normalizeAndStage (SHARED path with WavSourceDecoder).
//
// Whole-file buffer is the M2 import design (same memory shape as
// WavSourceDecoder); P-202 owns chunked streaming for separation. A 4-minute
// stereo 44.1k song peaks ~85 MB of Float32 — inside the §8 budget, and the
// staging WAV is freed with the workDir per C-2.2.
//
// Lossless containers (WAV/FLAC/ALAC) decode bit-identically here and in the
// ffmpeg reference (macOS ImportKitTests prove it against the committed
// fixtures); MP3 is decoder-dependent (CoreAudio vs ffmpeg) — tolerance-based
// comparison, documented honestly in the tests.

public struct AVAudioFileDecoder: AudioDecoding {
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
        let capacity = max(AVAudioFrameCount(file.length), 1)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw EngineError.unsupportedFormat(
                "cannot allocate \(capacity)-frame decode buffer for \(source.lastPathComponent)")
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw EngineError.unsupportedFormat(
                "decode failed for \(source.lastPathComponent): \(error.localizedDescription)")
        }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        guard frames > 0, channels >= 1 else {
            throw EngineError.unsupportedFormat(
                "empty decode (\(frames) frames, \(channels) ch) for \(source.lastPathComponent)")
        }

        // Deinterleaved channel planes → interleaved source-rate samples.
        guard let planes = buffer.floatChannelData else {
            throw EngineError.unsupportedFormat(
                "non-float decode format for \(source.lastPathComponent)")
        }
        var interleaved = [Float](repeating: 0, count: frames * channels)
        for c in 0..<channels {
            let plane = planes[c]
            for f in 0..<frames {
                interleaved[f * channels + c] = plane[f]
            }
        }
        return try Self.normalizeAndStage(
            (samples: interleaved, sampleRate: Int(format.sampleRate), channels: channels),
            workDir: workDir)
    }
}
