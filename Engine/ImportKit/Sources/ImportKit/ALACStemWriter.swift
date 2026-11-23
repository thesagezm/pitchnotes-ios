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
// and copies the source's deinterleaved planes into it.
//
// WHY A STRATEGY LADDER (P-204, after the first macOS RUNTIME verdict):
// the ALAC encode failed at runtime in every test with ONE opaque error —
// "The operation couldn't be completed. (Foundation._GenericObjCError error
// 0.)" — which says nothing about WHICH step failed (opening the output,
// reading the source, or writing a chunk) nor WHY. Linux cannot run
// AVFoundation at all, so the only way to make progress is to make ONE CI
// round trip DECISIVE: every plausible strategy is tried in order, every
// failure is recorded with its per-step diagnostics (domain, code, userInfo),
// and the aggregate error names every attempt. Two causes could not be ruled
// out from the source alone:
//   (a) the bit-depth HINT (`AVEncoderBitDepthHintKey`) contradicting the
//       float32 client format the encoder is fed;
//   (b) the `read(into:frameCount:)` overload refusing a SHORT final read
//       (a 44 100-frame source ends on a partial 3 140-frame chunk).
// The ladder covers both, plus the int16 client layout, and the first
// strategy that works wins — the winner is logged, so the next session
// knows which strategy the shipping path uses.

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
        /// Which encode strategy actually produced the file (the ladder's
        /// winner — e.g. "float32+hint16+frameCount"). Reported so the
        /// ladder can be trimmed to the ONE strategy the shipping path uses
        /// once the macOS verdict is recorded.
        public let strategy: String

        public init(part: Part, channels: Int, bytes: Int, durationSeconds: Double,
                    strategy: String = "") {
            self.part = part
            self.channels = channels
            self.bytes = bytes
            self.durationSeconds = durationSeconds
            self.strategy = strategy
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

        let baseSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatAppleLossless),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]

        // The ladder: every strategy is tried; EVERY failure is kept.
        var failures: [String] = []
        for plan in Self.plans(sourceBitDepth: sourceBitDepth) {
            do {
                try Self.encode(plan: plan,
                                source: source,
                                destination: destination,
                                baseSettings: baseSettings)
            } catch let error as EngineError {
                failures.append(error.message)
                try? fm.removeItem(at: destination)
                continue
            } catch {
                failures.append("\(plan.name): \(Self.describe(error))")
                try? fm.removeItem(at: destination)
                continue
            }

            // SUCCESS — the `.m4a` is finalised (the output file was released
            // when the strategy returned), so the size can be measured.
            let attributes = try? fm.attributesOfItem(atPath: destination.path)
            let byteCount = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            let duration = sampleRate > 0 ? Double(frames) / sampleRate : 0
            let info = EncodedStemInfo(part: part, channels: channels,
                                       bytes: byteCount, durationSeconds: duration,
                                       strategy: plan.name)

            let mbPerMinute = String(format: "%.3f", info.megabytesPerMinute)
            let seconds = String(format: "%.1f", duration)
            Self.logger.info("stem \(part.rawValue, privacy: .public) encoded via \(plan.name, privacy: .public): \(byteCount) bytes (\(mbPerMinute, privacy: .public) MB/min over \(seconds, privacy: .public) s, \(channels) ch, ALAC)")

            return info
        }

        throw EngineError.importFailed(
            "ALACStemWriter: every ALAC strategy failed for \(part.rawValue) "
            + "(\(failures.count) attempts): " + failures.joined(separator: " || "))
    }

    // MARK: - The strategy ladder

    /// The client (processing) layout the ALAC encoder is fed.
    private enum ClientLayout {
        case float32
        case int16

        var commonFormat: AVAudioCommonFormat {
            switch self {
            case .float32: return .pcmFormatFloat32
            case .int16: return .pcmFormatInt16
            }
        }
    }

    /// How the source is read.
    private enum ReadStrategy {
        /// `read(into:frameCount:)` — exact frame counts (the newer overload).
        case frameCount
        /// `read(into:)` — the older overload the decoder uses (proven on
        /// every committed fixture); it fills the buffer up to its capacity
        /// and reports the frames it read in the buffer's `frameLength`.
        case wholeBuffer
    }

    /// One encode strategy.
    private struct EncodePlan {
        let name: String
        let layout: ClientLayout
        /// `nil` ⇒ no `AVEncoderBitDepthHintKey` in the settings at all.
        let bitDepthHint: Int?
        let read: ReadStrategy
    }

    /// The strategies, in the order they are tried.
    ///
    /// The FIRST plan is the one the docs describe (float32, planar, with the
    /// source's bit-depth hint). The variants below cover the two plausible
    /// causes of the opaque runtime failure, plus the int16 client layout:
    /// the hint contradicting the client format, and the frame-count read
    /// refusing a short final chunk.
    private static func plans(sourceBitDepth: Int) -> [EncodePlan] {
        [
            EncodePlan(name: "float32+hint\(sourceBitDepth)+frameCount",
                       layout: .float32, bitDepthHint: sourceBitDepth, read: .frameCount),
            EncodePlan(name: "float32+nohint+frameCount",
                       layout: .float32, bitDepthHint: nil, read: .frameCount),
            EncodePlan(name: "float32+hint\(sourceBitDepth)+wholeBuffer",
                       layout: .float32, bitDepthHint: sourceBitDepth, read: .wholeBuffer),
            EncodePlan(name: "float32+nohint+wholeBuffer",
                       layout: .float32, bitDepthHint: nil, read: .wholeBuffer),
            EncodePlan(name: "int16+hint16+wholeBuffer",
                       layout: .int16, bitDepthHint: 16, read: .wholeBuffer),
            EncodePlan(name: "int16+nohint+wholeBuffer",
                       layout: .int16, bitDepthHint: nil, read: .wholeBuffer),
        ]
    }

    /// Runs one strategy end to end.
    ///
    /// Every failure carries the step it happened in (open / read / copy /
    /// write) plus the NSError's domain, code and userInfo — the aggregate
    /// report is what makes the next CI round trip decisive.
    private static func encode(plan: EncodePlan,
                               source: URL,
                               destination: URL,
                               baseSettings: [String: Any]) throws {
        var settings = baseSettings
        if let hint = plan.bitDepthHint {
            settings[AVEncoderBitDepthHintKey] = hint
        }

        // A FRESH input file per strategy: a failed attempt leaves the read
        // position in the middle of the source.
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw EngineError.importFailed(
                "ALACStemWriter: [\(plan.name)] cannot open the source: \(describe(error))")
        }

        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(forWriting: destination,
                                        settings: settings,
                                        commonFormat: plan.layout.commonFormat,
                                        interleaved: false)
        } catch {
            throw EngineError.importFailed(
                "ALACStemWriter: [\(plan.name)] cannot create \(destination.lastPathComponent): \(describe(error))")
        }

        let inFormat = input.processingFormat
        let outFormat = outputFile.processingFormat
        guard outFormat.channelCount == inFormat.channelCount,
              outFormat.sampleRate == inFormat.sampleRate else {
            throw EngineError.contractViolation(
                "ALACStemWriter: [\(plan.name)] output processing format "
                + "(\(outFormat.channelCount) ch @ \(outFormat.sampleRate) Hz) does not match the source "
                + "(\(inFormat.channelCount) ch @ \(inFormat.sampleRate) Hz)")
        }
        // The encoder is fed PLANAR buffers (the ALAC encoder's own layout);
        // AVAudioFile's processing format is float32 deinterleaved, so both
        // sides are planar and the copy is a straight per-plane copy.
        guard !inFormat.isInterleaved, !outFormat.isInterleaved else {
            throw EngineError.contractViolation(
                "ALACStemWriter: [\(plan.name)] interleaved processing formats are not supported "
                + "(in interleaved=\(inFormat.isInterleaved), out interleaved=\(outFormat.isInterleaved))")
        }

        let chunkFrames: AVAudioFrameCount = 8192
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunkFrames),
              let writeBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunkFrames) else {
            throw EngineError.importFailed(
                "ALACStemWriter: [\(plan.name)] cannot allocate the PCM buffers")
        }

        let totalFrames = Int(input.length)
        var framesWritten = 0
        while framesWritten < totalFrames {
            let remaining = totalFrames - framesWritten
            let want = AVAudioFrameCount(min(Int(chunkFrames), remaining))
            let count: Int
            switch plan.read {
            case .frameCount:
                do {
                    try input.read(into: readBuffer, frameCount: want)
                } catch {
                    throw EngineError.importFailed(
                        "ALACStemWriter: [\(plan.name)] read failed at frame \(framesWritten)/\(totalFrames): \(describe(error))")
                }
                count = Int(readBuffer.frameLength)
            case .wholeBuffer:
                // The older overload: it reads up to the buffer's capacity and
                // reports the frames it read in the buffer's `frameLength`.
                do {
                    try input.read(into: readBuffer)
                } catch {
                    throw EngineError.importFailed(
                        "ALACStemWriter: [\(plan.name)] read failed at frame \(framesWritten)/\(totalFrames): \(describe(error))")
                }
                count = Int(readBuffer.frameLength)
            }
            if count == 0 {
                throw EngineError.importFailed(
                    "ALACStemWriter: [\(plan.name)] the source ended after \(framesWritten)/\(totalFrames) frames")
            }
            let copied = count
            do {
                try copyFrames(from: readBuffer, to: writeBuffer, frames: copied)
            } catch let error as EngineError {
                throw EngineError.importFailed(
                    "ALACStemWriter: [\(plan.name)] copy failed: \(error.message)")
            }
            writeBuffer.frameLength = AVAudioFrameCount(copied)
            do {
                try outputFile.write(from: writeBuffer)
            } catch {
                throw EngineError.importFailed(
                    "ALACStemWriter: [\(plan.name)] write failed at frame \(framesWritten): \(describe(error))")
            }
            framesWritten += copied
        }
        // `outputFile` is released here → the ALAC encoder flushes and the
        // `.m4a` container is finalised.
    }

    /// Copies `frames` frames from the source buffer (float32 planes — the
    /// format AVAudioFile decodes into) into the destination buffer (whatever
    /// client layout the encoder accepted).
    private static func copyFrames(from source: AVAudioPCMBuffer,
                                   to destination: AVAudioPCMBuffer,
                                   frames: Int) throws {
        let channels = Int(source.format.channelCount)
        guard let srcPlanes = source.floatChannelData else {
            throw EngineError.importFailed("the source buffer has no float channel data")
        }
        if let dstPlanes = destination.floatChannelData {
            for c in 0..<channels {
                dstPlanes[c].update(from: srcPlanes[c], count: frames)
            }
            return
        }
        if let dstPlanes = destination.int16ChannelData {
            for c in 0..<channels {
                let src = srcPlanes[c]
                let dst = dstPlanes[c]
                for f in 0..<frames {
                    let scaled = Double(src[f]) * 32767.0
                    let clamped = max(-32768.0, min(32767.0, scaled))
                    dst[f] = Int16(clamping: Int32(clamped))
                }
            }
            return
        }
        throw EngineError.importFailed("the destination buffer has no supported PCM layout")
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

private extension EngineError {
    /// The error's message (every case carries a human-readable string).
    var message: String {
        switch self {
        case .importFailed(let text), .unsupportedFormat(let text),
             .separationFailed(let text), .modelMissing(let text),
             .contractViolation(let text):
            return text
        }
    }
}
