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
//
// THE RUNTIME FAILURE AND ITS ROOT CAUSE (P-204, measured on the macOS
// runner — run 45156291152@1935a0f GREEN, 8/8): the encode used to die with
// ONE opaque error ("The operation couldn't be completed.
// (Foundation._GenericObjCError error 0.)") for every stem, mono and stereo.
// The cause is NOT the encoder, NOT the settings and NOT the bit-depth hint:
// `AVAudioFile.read(into:frameCount:)` **throws when the source has fewer
// frames left than the requested count**, and the old loop always asked for a
// FULL 8 192-frame chunk — a 44 100-frame stem ends on a 3 140-frame
// remainder, so every encode failed on its LAST read. The fix is to request
// exactly the frames that remain. (This was found with a temporary STRATEGY
// LADDER — six variants of the client layout / read overload, every failure
// reported per step with its NSError domain, code and userInfo — because
// Linux cannot run AVFoundation and the failure mode was identical for every
// cause. The ladder's winner was the first, documented variant, which pinned
// the cause; the ladder is GONE and only the proven path remains, with the
// per-step diagnostics kept so a future failure names the step that broke.)
//
// PER-STEP DIAGNOSTICS (kept deliberately): the encode reports the step it
// failed in — open / read / copy / write — with the NSError's domain, code
// and userInfo. "It didn't work" is not an acceptable error message for a
// native-codec path.

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

        // Open the source ONCE for the policy checks (channels / rate / depth).
        let probe: AVAudioFile
        do {
            probe = try AVAudioFile(forReading: source)
        } catch {
            throw EngineError.importFailed(
                "ALACStemWriter: cannot read staged stem \(source.lastPathComponent): \(Self.describe(error))")
        }

        let format = probe.processingFormat
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
        let sourceBitDepth = (probe.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int) ?? 16
        let frames = Int(probe.length)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatAppleLossless),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitDepthHintKey: sourceBitDepth,
        ]

        do {
            try Self.encodeALAC(source: source,
                                destination: destination,
                                settings: settings,
                                part: part)
        } catch let error as EngineError {
            // A partial `.m4a` must never survive a failed encode.
            try? fm.removeItem(at: destination)
            throw error
        } catch {
            try? fm.removeItem(at: destination)
            throw EngineError.importFailed(
                "ALACStemWriter: ALAC encode failed for \(part.rawValue): \(Self.describe(error))")
        }

        // The `.m4a` is finalised (the output file was released when the
        // encode returned), so the size can be measured.
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

    /// Streams `source` into an ALAC `.m4a` at `destination`.
    ///
    /// The encoder is fed 8 192-frame chunks so a whole song's stem never
    /// exists as one buffer (§8 memory budget). Every failure carries the
    /// step it happened in (open / read / copy / write).
    private static func encodeALAC(source: URL,
                                   destination: URL,
                                   settings: [String: Any],
                                   part: Part) throws {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw EngineError.importFailed(
                "ALACStemWriter: [\(part.rawValue)] cannot open the source: \(describe(error))")
        }

        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(forWriting: destination,
                                        settings: settings,
                                        commonFormat: .pcmFormatFloat32,
                                        interleaved: false)
        } catch {
            throw EngineError.importFailed(
                "ALACStemWriter: [\(part.rawValue)] cannot create \(destination.lastPathComponent): \(describe(error))")
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
        // planar float32 and the copy is a straight per-plane copy.
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

        let totalFrames = Int(input.length)
        var framesWritten = 0
        while framesWritten < totalFrames {
            // **Ask for exactly the frames that remain.** `read(into:frameCount:)`
            // THROWS when the source has fewer frames left than requested —
            // asking for a full chunk at the tail of the file was the root
            // cause of the opaque encode failure (see the file header).
            let remaining = totalFrames - framesWritten
            let want = AVAudioFrameCount(min(Int(chunkFrames), remaining))
            do {
                try input.read(into: readBuffer, frameCount: want)
            } catch {
                throw EngineError.importFailed(
                    "ALACStemWriter: [\(part.rawValue)] read failed at frame \(framesWritten)/\(totalFrames): \(describe(error))")
            }
            let count = Int(readBuffer.frameLength)
            if count == 0 {
                throw EngineError.importFailed(
                    "ALACStemWriter: [\(part.rawValue)] the source ended after \(framesWritten)/\(totalFrames) frames")
            }
            do {
                try copyFrames(from: readBuffer, to: writeBuffer, frames: count)
            } catch {
                throw EngineError.importFailed(
                    "ALACStemWriter: [\(part.rawValue)] copy failed: \(error.localizedDescription)")
            }
            writeBuffer.frameLength = AVAudioFrameCount(count)
            do {
                try outputFile.write(from: writeBuffer)
            } catch {
                throw EngineError.importFailed(
                    "ALACStemWriter: [\(part.rawValue)] write failed at frame \(framesWritten): \(describe(error))")
            }
            framesWritten += count
        }
        // `outputFile` is released here → the ALAC encoder flushes and the
        // `.m4a` container is finalised.
    }

    /// Copies `frames` frames from the source buffer (float32 planes — the
    /// format AVAudioFile decodes into) into the destination buffer.
    private static func copyFrames(from source: AVAudioPCMBuffer,
                                   to destination: AVAudioPCMBuffer,
                                   frames: Int) throws {
        let channels = Int(source.format.channelCount)
        guard let srcPlanes = source.floatChannelData,
              let dstPlanes = destination.floatChannelData else {
            throw EngineError.importFailed("the PCM buffers have no float channel data")
        }
        for c in 0..<channels {
            dstPlanes[c].update(from: srcPlanes[c], count: frames)
        }
    }

    /// A compact diagnostic rendering of an error: domain, code, the localized
    /// description and the userInfo. The ALAC encoder's failures are opaque
    /// without it.
    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var text = "\(ns.domain) code \(ns.code): \(ns.localizedDescription)"
        if !ns.userInfo.isEmpty {
            let rendered = String(describing: ns.userInfo)
            text += " userInfo=" + String(rendered.prefix(400))
        }
        return text
    }
}
