import Foundation
import AVFoundation
import AudioToolbox
import os
import EngineCore

// P-204 · ALAC stem writer (Apple-only conformer of EngineCore's
// `StemEncoding` seam).
//
// C-2 requires the stems to be ALAC `.m4a` at 44.1 kHz (§6: "stems are
// written as ALAC .m4a (native encoder); no ffmpeg on device"). AVFoundation's
// ALAC encoder is native — no external tool, no network, no second codec stack.
//
// Channel policy (D-8) is enforced by the ORCHESTRATOR (it checks what the
// writer reports): voice stems MONO, INSTRUMENTAL STEREO.
//
// Memory: the source WAV is streamed in 8 192-frame chunks — a 4-minute
// stereo stem never materialises as one buffer (§8 memory budget).
//
// WRITER CHOICE (P-204, after the macOS compile verdict): `AVAssetWriterInput`
// on this SDK only accepts a `CMSampleBuffer` (its `AVAudioPCMBuffer`
// overload does not exist), which would mean hand-building a
// `CMAudioFormatDescription` + `AudioBufferList` per chunk. `AVAudioFile`
// does the same job natively — it owns the ALAC encoder, accepts plain PCM
// buffers and finalises the `.m4a` container when it is released — so the
// writer uses `AVAudioFile(forWriting:settings:commonFormat:interleaved:)`
// with a float32 / non-interleaved processing format (the only layout the
// ALAC encoder accepts) and copies the source's deinterleaved planes into it.

public struct ALACStemWriter: StemEncoding {

    public init() {}

    /// What one encoded stem cost on disk.
    ///
    /// §8's storage budget is "ALAC stems ≈ 5–6 MB/min/stem" — that figure is
    /// for real music, so `megabytesPerMinute` on a synthetic sine fixture is
    /// expected to be far BELOW it (ALAC compresses a pure tone enormously).
    /// The number is reported so the §8 figure can be checked against real
    /// imports, never to assert it on synthetic audio.
    public struct EncodedStemInfo: Sendable {
        public let part: Part
        public let channels: Int
        public let bytes: Int
        public let durationSeconds: Double

        public init(part: Part, channels: Int, bytes: Int, durationSeconds: Double) {
            self.part = part
            self.channels = channels
            self.bytes = bytes
            self.durationSeconds = durationSeconds
        }

        /// Megabytes (10^6 bytes) per minute of audio.
        public var megabytesPerMinute: Double {
            guard durationSeconds > 0 else { return 0 }
            let minutes = durationSeconds / 60.0
            return (Double(bytes) / 1_000_000.0) / minutes
        }
    }

    private static let logger = Logger(subsystem: "com.thesagezm.pitchnotes", category: "import")

    /// Encodes the staged PCM WAV at `source` into an ALAC `.m4a` at
    /// `destination`; returns the channel count actually written.
    public func encodeStem(source: URL, destination: URL, part: Part) throws -> Int {
        try encodeStemWithInfo(source: source, destination: destination, part: part).channels
    }

    /// Same as `encodeStem`, but also reports the encoded size (§8 storage
    /// budget). The extra information is returned rather than only logged so
    /// the macOS test can assert it (a log line cannot be asserted).
    public func encodeStemWithInfo(source: URL, destination: URL, part: Part) throws -> EncodedStemInfo {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)

        let inputFile: AVAudioFile
        do {
            inputFile = try AVAudioFile(forReading: source)
        } catch {
            throw EngineError.importFailed(
                "ALACStemWriter: cannot read staged stem \(source.lastPathComponent): \(error.localizedDescription)")
        }

        let format = inputFile.processingFormat
        let channels = Int(format.channelCount)
        let sampleRate = format.sampleRate
        guard channels == 1 || channels == 2 else {
            throw EngineError.contractViolation(
                "ALACStemWriter: stem \(part.rawValue) has \(channels) channels; D-8 allows 1 (voice) or 2 (instrumental)")
        }
        guard sampleRate == Double(DecodePolicy.targetSampleRate) else {
            throw EngineError.unsupportedFormat(
                "ALACStemWriter: stem sample rate \(sampleRate) ≠ \(DecodePolicy.targetSampleRate) (D-8)")
        }

        // Preserve the source's PCM depth (the engine's stems are PCM16).
        let sourceBitDepth = (inputFile.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int) ?? 16
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatAppleLossless),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitDepthHintKey: sourceBitDepth,
        ]

        // The output file lives inside `writeALAC` so that it is RELEASED —
        // and the `.m4a` container finalised — before the size is measured and
        // before the caller reads the file back.
        let frames = Int(inputFile.length)
        do {
            try Self.writeALAC(input: inputFile,
                               destination: destination,
                               settings: settings,
                               part: part)
        } catch let error as EngineError {
            try? fm.removeItem(at: destination)
            throw error
        } catch {
            try? fm.removeItem(at: destination)
            throw EngineError.importFailed(
                "ALACStemWriter: ALAC encode failed for \(part.rawValue): \(error.localizedDescription)")
        }

        let attributes = try? fm.attributesOfItem(atPath: destination.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let duration = sampleRate > 0 ? Double(frames) / sampleRate : 0
        let info = EncodedStemInfo(part: part, channels: channels,
                                   bytes: byteCount, durationSeconds: duration)

        let mbPerMinute = String(format: "%.3f", info.megabytesPerMinute)
        let seconds = String(format: "%.1f", duration)
        Self.logger.info("stem \(part.rawValue, privacy: .public) encoded: \(byteCount) bytes (\(mbPerMinute, privacy: .public) MB/min over \(seconds, privacy: .public) s, \(channels) ch, ALAC)")

        return info
    }

    // MARK: - The ALAC encode

    /// Streams `input` into an ALAC `.m4a` at `destination`.
    ///
    /// The encoder is fed 8 192-frame chunks so a whole song's stem never
    /// exists as one buffer (§8 memory budget).
    private static func writeALAC(input: AVAudioFile,
                                  destination: URL,
                                  settings: [String: Any],
                                  part: Part) throws {
        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(forWriting: destination,
                                        settings: settings,
                                        commonFormat: .pcmFormatFloat32,
                                        interleaved: false)
        } catch {
            throw EngineError.importFailed(
                "ALACStemWriter: cannot create \(destination.lastPathComponent): \(error.localizedDescription)")
        }

        let inFormat = input.processingFormat
        let outFormat = outputFile.processingFormat
        guard outFormat.channelCount == inFormat.channelCount,
              outFormat.sampleRate == inFormat.sampleRate else {
            throw EngineError.contractViolation(
                "ALACStemWriter: output processing format (\(outFormat.channelCount) ch @ \(outFormat.sampleRate) Hz) "
                + "does not match the source (\(inFormat.channelCount) ch @ \(inFormat.sampleRate) Hz)")
        }
        // The ALAC encoder takes float32 PLANAR buffers; AVAudioFile's
        // processing format is float32 deinterleaved, so both sides are
        // planar float32 and the copy is a straight per-plane memcpy.
        guard !inFormat.isInterleaved, !outFormat.isInterleaved else {
            throw EngineError.contractViolation(
                "ALACStemWriter: interleaved processing formats are not supported "
                + "(in interleaved=\(inFormat.isInterleaved), out interleaved=\(outFormat.isInterleaved))")
        }

        let chunkFrames: AVAudioFrameCount = 8192
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunkFrames),
              let writeBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunkFrames) else {
            throw EngineError.importFailed("ALACStemWriter: cannot allocate the PCM buffers")
        }

        let channels = Int(inFormat.channelCount)
        while true {
            // `read(into:frameCount:)` reports EOF through `frameLength == 0`.
            try input.read(into: readBuffer, frameCount: chunkFrames)
            let count = Int(readBuffer.frameLength)
            if count == 0 { break }

            writeBuffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<channels {
                guard let source = readBuffer.floatChannelData?[channel],
                      let target = writeBuffer.floatChannelData?[channel] else {
                    throw EngineError.importFailed(
                        "ALACStemWriter: no float channel data for \(part.rawValue) channel \(channel)")
                }
                target.update(from: source, count: count)
            }
            try outputFile.write(from: writeBuffer)
        }
        // `outputFile` is released here → the ALAC encoder flushes and the
        // `.m4a` container is finalised.
    }
}
