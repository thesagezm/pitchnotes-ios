import Foundation
import AVFoundation
import EngineCore

// SessionALACRecorder (P-403, PAUL lane) — the Apple-side half of the
// session recording: mic chunks (16 kHz mono, the CapturePipeline's contract
// rate) → ALAC .m4a, aligned to the session through the portable
// `SessionRecordingAlignment` (EngineCore). The POLICY (default OFF,
// local-only, purge semantics) lives in EngineCore's
// `SessionRecordingPolicy` / `SessionRecordingStore` (Linux-tested); this
// file only binds the encoder and enforces the same default INDEPENDENTLY —
// an append to a recorder that was never enabled refuses, so a UI wiring
// mistake cannot silently start recording (defence in depth; the policy is
// the product promise, this is the file's own guard).
//
// ALAC via AVAudioFile (the P-204 precedent — the native encoder, no
// ffmpeg; the stem writer proved the encode works headless on the runner).

/// The session recording writer. ONE recording per instance.
public final class SessionALACRecorder {

    public enum RecorderError: Error, Equatable {
        /// An append (or a start) arrived while the recorder was disabled —
        /// THE DEFAULT-OFF GUARD (P-403's AC, enforced at the writer too).
        case recordingDisabled
        /// start() on an already-open recording.
        case alreadyRecording
        /// append/stop without start().
        case notRecording
        /// The chunk's rate is not the contract rate.
        case sampleRateMismatch(Int)
    }

    /// The device-local opt-in. **Defaults to FALSE** — the session UI must
    /// set it true only from the user's explicit setting (never a silent
    /// default-on).
    public var isEnabled: Bool = SessionRecordingPolicy.defaultEnabled

    /// The manifest being built (nil until start()).
    public private(set) var manifest: SessionRecordingManifest?

    /// Recorded 16 kHz frames so far.
    public private(set) var frameCount: Int = 0

    private var file: AVAudioFile?
    private let format = AVAudioFormat(standardFormatWithSampleRate: Double(SessionRecordingPolicy.sampleRate),
                                       channels: 1)!

    public init() {}

    /// Open the recording at `url` for a session described by `manifest`.
    /// The alignment's `bundleTimeAtSessionStart_s` is the playback position
    /// the session starts from (B₀); `captureTimeAtSessionStart_s` is the
    /// capture clock then (C₀) — the app reads both from its own clocks
    /// (the player's position clock and the capture engine's timestamps).
    public func start(url: URL, manifest: SessionRecordingManifest) throws {
        guard isEnabled else {
            throw RecorderError.recordingDisabled
        }
        guard file == nil else {
            throw RecorderError.alreadyRecording
        }
        // ALAC settings: the native lossless encoder, 16 kHz mono, 16-bit
        // (ALAC's legal depths: 16/20/24/32).
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: Double(SessionRecordingPolicy.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        self.file = try AVAudioFile(forWriting: url, settings: settings)
        self.manifest = manifest
        self.frameCount = 0
    }

    /// Append one chunk of CONTRACT-rate mono samples (what the capture
    /// pipeline drained). Refuses when the recorder is disabled (the
    /// default-off guard) or not started.
    public func append(_ samples: [Float], sampleRate: Int) throws {
        guard isEnabled else {
            throw RecorderError.recordingDisabled
        }
        guard sampleRate == SessionRecordingPolicy.sampleRate else {
            throw RecorderError.sampleRateMismatch(sampleRate)
        }
        guard let file else {
            throw RecorderError.notRecording
        }
        guard !samples.isEmpty else { return }
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: samples.count)
            }
        }
        try file.write(from: buffer)
        frameCount += samples.count
        manifest?.frameCount = frameCount
    }

    /// Finalize the file. The manifest (with the final frameCount) is what
    /// the caller hands to `SessionRecordingStore.writeManifest`.
    @discardableResult
    public func stop() throws -> SessionRecordingManifest? {
        guard let file else {
            throw RecorderError.notRecording
        }
        // AVAudioFile finalizes on dealloc; dropping the reference closes
        // the container (the P-204 writer's convention).
        self.file = nil
        manifest?.frameCount = frameCount
        return manifest
    }
}
