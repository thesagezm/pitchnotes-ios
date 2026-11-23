import Foundation
import AVFoundation
import AudioToolbox
import EngineCore

// P-204 · ALAC stem writer (Apple-only conformer of EngineCore's
// `StemEncoding` seam).
//
// C-2 requires the stems to be ALAC `.m4a` at 44.1 kHz (§6: "stems are
// written as ALAC .m4a (native encoder); no ffmpeg on device"). AVFoundation's
// AVAssetWriter encodes Apple Lossless natively — no external tool, no
// network, no second codec stack.
//
// Channel policy (D-8) is enforced by the ORCHESTRATOR (it checks what the
// writer reports): voice stems MONO, INSTRUMENTAL STEREO.
//
// Memory: the source WAV is streamed in 8 192-frame chunks — a 4-minute
// stereo stem never materialises as one buffer (§8 memory budget).

public struct ALACStemWriter: StemEncoding {

    public init() {}

    /// Encodes the staged PCM WAV at `source` into an ALAC `.m4a` at
    /// `destination`; returns the channel count actually written.
    public func encodeStem(source: URL, destination: URL, part: Part) throws -> Int {
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

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        } catch {
            throw EngineError.importFailed(
                "ALACStemWriter: cannot create \(destination.lastPathComponent): \(error.localizedDescription)")
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw EngineError.importFailed(
                "ALACStemWriter: writer rejected the ALAC input for \(part.rawValue)")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw EngineError.importFailed(
                "ALACStemWriter: startWriting failed: \(writer.error?.localizedDescription ?? "unknown")")
        }
        writer.startSession(atSourceTime: .zero)

        let chunkFrames: AVAudioFrameCount = 8192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            writer.cancelWriting()
            throw EngineError.importFailed("ALACStemWriter: cannot allocate the PCM buffer")
        }

        // The media-data callback runs on its own queue; the semaphore hands
        // the result back to this (synchronous) call site.
        let queue = DispatchQueue(label: "com.thesagezm.pitchnotes.alac-writer")
        let finished = DispatchSemaphore(value: 0)
        let failure = FailureBox()

        input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData {
                // `read(into:frameCount:)` is non-throwing on the current
                // AVFoundation SDK and reports EOF through `frameLength == 0`
                // (an older overload returned the frame count instead — not
                // available here).
                do {
                    try inputFile.read(into: buffer, frameCount: chunkFrames)
                } catch {
                    failure.set(error)
                    input.markAsFinished()
                    finished.signal()
                    return
                }
                if buffer.frameLength == 0 {
                    input.markAsFinished()
                    finished.signal()
                    return
                }
                if !input.append(buffer) {
                    failure.set(writer.error ?? EngineError.importFailed(
                        "ALACStemWriter: append failed for \(part.rawValue)"))
                    input.markAsFinished()
                    finished.signal()
                    return
                }
            }
        }

        finished.wait()
        if let error = failure.get() {
            writer.cancelWriting()
            try? fm.removeItem(at: destination)
            throw error
        }

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()

        guard writer.status == .completed else {
            let error = writer.error ?? EngineError.importFailed(
                "ALACStemWriter: finishWriting failed for \(part.rawValue)")
            try? fm.removeItem(at: destination)
            throw error
        }

        return channels
    }
}

/// Thread-safe one-slot error box (the media-data callback runs off-thread).
private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func set(_ e: Error) {
        lock.lock(); error = e; lock.unlock()
    }

    func get() -> Error? {
        lock.lock(); defer { lock.unlock() }; return error
    }
}
