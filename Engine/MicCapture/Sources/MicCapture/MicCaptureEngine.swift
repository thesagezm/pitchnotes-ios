import Foundation
import AVFoundation
import EngineCore

// P-104 · Apple mic-capture wrapper (PAUL lane). THIN on purpose: every
// policy decision (ring depth, drop semantics, resampling continuity) lives
// in the portable EngineCore CapturePipeline (Linux-tested); this file only
// binds the device:
//
//   AVAudioEngine input tap (render-adjacent audio queue, 1024-frame @48 kHz
//   = 21.33 ms) → AVAudioConverter (input rate → 16 kHz mono, stateful —
//   Apple handles continuity) → CapturePipeline.submit (never blocks) →
//   drained hop-sized MicChunks delivered on `onChunk` (engine queue).
//
// Threading: the tap fires on AVFoundation's internal audio queue. The
// callback does ONLY: convert + submit + drain (all memcpy-bounded, < 1 ms)
// and hops to `callbackQueue` for the consumer. No allocation-heavy work, no
// locks held across I/O (§8 live-path rules).
//
// Latency budget (§8 < 100 ms; ENGINE.md §1.2): capture 21.3 ms (tap frame) +
// convert < 1 ms + drain-to-facade ≤ 16 ms (hop) + ribbon ~4 ms measured.
// TRUE end-to-end loopback is measured on device (J-403 hook, later).
//
// Audio session (iOS): .playAndRecord. `usesVoiceProcessing` = OFF by default
// for fidelity with headphones (full-band capture); the UI should flip it ON
// when output routes to the speaker (AEC kills the howl loop). Jess owns the
// UX policy (J-102); this type just exposes the toggle + route observations.

public final class MicCaptureEngine: @unchecked Sendable {

    public struct Config: Sendable {
        /// Requested input rate (device native is typically 48 kHz).
        public var sourceSampleRate: Int
        /// Tap buffer size in frames at `sourceSampleRate` (1024 = 21.33 ms).
        public var frameSamples: Int
        /// Ring depth in seconds of 16 kHz audio (1.0 s absorbs jitter).
        public var ringCapacitySeconds: Double
        /// iOS: .voiceChat mode (AEC+AGC) — ON when output goes to the
        /// speaker, OFF for headphone fidelity. Default OFF.
        public var usesVoiceProcessing: Bool

        public init(sourceSampleRate: Int = CaptureSpec.sourceSampleRate,
                    frameSamples: Int = CaptureSpec.frameSamples,
                    ringCapacitySeconds: Double = 1.0,
                    usesVoiceProcessing: Bool = false) {
            self.sourceSampleRate = sourceSampleRate
            self.frameSamples = frameSamples
            self.ringCapacitySeconds = ringCapacitySeconds
            self.usesVoiceProcessing = usesVoiceProcessing
        }
    }

    /// Drained 16 kHz chunks (hop-aligned) on `callbackQueue`. Set BEFORE
    /// `start()`. Typical body: `facade.ribbonFrame(chunk)`.
    public var onChunk: ((MicChunk) -> Void)?

    /// Interruption began (call, route failure, media services reset) — the
    /// pipeline has ALREADY been reset by the time this fires.
    public var onInterruption: (() -> Void)?

    /// Queue `onChunk`/`onInterruption` fire on. Default: a dedicated serial
    /// queue (NOT the tap's audio queue).
    public let callbackQueue: DispatchQueue

    /// Consumer-visible pipeline (stats, reset, advanced pull-based use).
    public let pipeline: CapturePipeline

    public private(set) var isRunning = false

    private let config: Config
    private let engine = AVAudioEngine()
    /// 16 kHz mono target, built ONCE (never on the audio path).
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: Double(CaptureSpec.targetSampleRate),
                                             channels: 1, interleaved: false)
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let stateLock = NSLock()

    public init(config: Config = Config(),
                callbackQueue: DispatchQueue = DispatchQueue(label: "pitchnotes.miccapture.engine", qos: .userInteractive)) {
        self.config = config
        self.callbackQueue = callbackQueue
        self.pipeline = CapturePipeline(capacitySeconds: config.ringCapacitySeconds,
                                        sourceSampleRate: config.sourceSampleRate)
    }

    // MARK: - Start / stop

    public func start() throws {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !isRunning else { return }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                mode: config.usesVoiceProcessing ? .voiceChat : .default,
                                options: [.defaultToSpeaker, .allowBluetooth])
        // Preferred IO buffer ≈ frameSamples @ source rate (best effort).
        let preferred = AVAudioFrameCount(Double(config.frameSamples) / Double(config.sourceSampleRate) * session.sampleRate)
        try? session.setPreferredIOBufferDuration(Double(preferred) / session.sampleRate)
        try session.setActive(true)
        #endif

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "PitchNotes.MicCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "input node has no format (mic unavailable?)"])
        }
        installTapIfNeeded(inputFormat: inputFormat)

        #if os(iOS)
        observeSessionNotifications()
        #endif
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    public func stop() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        #if os(iOS)
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
        AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        pipeline.finish()
        isRunning = false
    }

    // MARK: - Tap + conversion

    private func installTapIfNeeded(inputFormat: AVAudioFormat) {
        guard converterInputFormat != inputFormat, let target16kMono = targetFormat else { return }
        engine.inputNode.removeTap(onBus: 0)
        converterInputFormat = inputFormat

        let conv = AVAudioConverter(from: inputFormat, to: target16kMono)
        converter = conv

        engine.inputNode.installTap(onBus: 0,
                                    bufferSize: AVAudioFrameCount(config.frameSamples),
                                    format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer)
        }
    }

    /// Runs on AVFoundation's audio queue: convert → submit → drain → deliver.
    private func handleTap(buffer: AVAudioPCMBuffer) {
        guard let conv = converter, let target16kMono = targetFormat else { return }

        // Capacity for the worst case: ratio rounded up + converter overhead.
        let ratio = Double(CaptureSpec.targetSampleRate) / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: target16kMono, frameCapacity: capacity) else { return }

        var fedInput = false
        var conversionError: NSError?
        let status = conv.convert(to: out, error: &conversionError) { _, outStatus in
            if fedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            fedInput = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, out.frameLength > 0,
              let channel = out.floatChannelData?[0] else { return }
        if status == .error { return }

        let samples = Array(UnsafeBufferPointer<Float>(start: UnsafePointer(channel),
                                                       count: Int(out.frameLength)))
        // captureTime: when the tap fired (process wall clock, seconds).
        let now = ProcessInfo.processInfo.systemUptime
        pipeline.submit(samples, sampleRate: CaptureSpec.targetSampleRate, captureTime_s: now)

        // Drain the hop and deliver on the engine queue. Ring overflow is
        // already drop-counted inside the pipeline (meters: snapshot()).
        let drained = pipeline.drain(maxSamples: Int.max)
        guard !drained.isEmpty else { return }
        let chunk = MicChunk(samples: drained,
                             sampleRate: CaptureSpec.targetSampleRate,
                             captureTime_s: now)
        callbackQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.onChunk?(chunk)
        }
    }

    // MARK: - Interruptions (iOS)

    #if os(iOS)
    private var notificationObservers: [NSObjectProtocol] = []

    private func observeSessionNotifications() {
        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                // Phone call / Siri: stop cleanly, reset capture state.
                self.stop()
                self.callbackQueue.async { self.onInterruption?() }
            case .ended:
                // Route settled — the app decides whether to restart (UI lane).
                break
            @unknown default:
                break
            }
        })
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            switch reason {
            case .oldDeviceUnavailable, .newDeviceAvailable, .categoryChange:
                // Route change ⇒ input format may have changed: rebuild the
                // converter on the next tap callback; drop stale buffered audio.
                self.pipeline.reset()
                self.stateLock.lock()
                self.converterInputFormat = nil // force reinstall at next tap
                self.stateLock.unlock()
            default:
                break
            }
        })
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.pipeline.reset()
            self.stop()
            self.callbackQueue.async { self.onInterruption?() }
        })
    }
    #endif
}
