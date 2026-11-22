import Foundation
import AVFoundation
import MediaPlayer
import EngineCore
import PitchLogic
import os

// MixerPlayer (J-203) — the AVAudioEngine path under MixerModel's pure
// logic. One AVAudioPlayerNode per manifest lane (C-2.2 stem naming, resolved
// via parts[].stemFile so MockEngine WAV bundles and P-204 ALAC bundles play
// IDENTICALLY — AVAudioFile decodes both). Stems are precomputed files: seek
// is an instant scheduleSegment at a frame offset, never a re-decode (UX §11
// A.1.2). Gain changes glide over ~15 ms (MixerModel.glideSamples) — no
// zipper noise (A.1.3).
//
// Background/lock-screen: MPRemoteCommandCenter + MPNowPlayingInfoCenter are
// wired here; X-021 landed UIBackgroundModes [audio] in project.yml (Leto,
// 2026-11-22 early rulings merge) so playback continues and lock-screen
// transport works. The runtime detection below STAYS as a drift guard — if
// the key disappears from the built plist, playback degrades to foreground-only
// with an honest notice (no crash, no promise we can't keep).
//
// D-12 honesty: the FOCUS preset attenuates (−12 dB), it does not solo; the
// UI labels carry that distinction (MixerView).

@MainActor
final class MixerPlayer: ObservableObject {

    /// UI-facing mirror of the transport (position ticks at ~10 Hz).
    @Published private(set) var transport: TransportModel
    @Published private(set) var mixer: MixerModel
    @Published private(set) var isEngineReady = false
    /// Honest degrade note while X-021 is pending (lock-screen step).
    @Published private(set) var backgroundNotice: String?

    let song: LibrarySong

    private var engine: AVAudioEngine?
    private var players: [Part: AVAudioPlayerNode] = [:]
    private var files: [Part: AVAudioFile] = [:]
    private var ticker: Timer?
    private var lastGainTargets: [Part: Double] = [:]
    private let logger = Logger(subsystem: "com.pitchnotes", category: "mixer")

    init(song: LibrarySong) {
        self.song = song
        let parts = song.manifest.parts.map(\.part)
        self.mixer = MixerModel(parts: parts, focusTarget: parts.first)
        var t = TransportModel(duration_s: song.manifest.duration_s)
        t.setLoop(start_s: 0, end_s: song.manifest.duration_s) // default A/B = whole song
        t.clearLoop()
        self.transport = t
        // X-021 is in the plist; if a future build drops the key, the
        // lock-screen step of the device demo (UX §10.2) degrades with this
        // honest notice rather than silently failing.
        if !Self.hasBackgroundAudioMode {
            backgroundNotice = "Background playback activates once the app gains the audio background mode (X-021) — foreground playback is fully functional."
        }
    }

    static var hasBackgroundAudioMode: Bool {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        return modes?.contains("audio") ?? false
    }

    var resolvedDuration: Double { song.manifest.duration_s }

    // MARK: - Engine lifecycle

    func prepare() {
        guard engine == nil else { return }
        let newEngine = AVAudioEngine()
        let mixerNode = newEngine.mainMixerNode

        guard let bundleDir = song.bundleDirectory else { return }
        for partInfo in song.manifest.parts {
            let url = bundleDir.appendingPathComponent(partInfo.stemFile)
            guard FileManager.default.fileExists(atPath: url.path) else {
                logger.error("stem missing: \(partInfo.stemFile, privacy: .public)")
                continue
            }
            do {
                let file = try AVAudioFile(forReading: url)
                let node = AVAudioPlayerNode()
                newEngine.attach(node)
                newEngine.connect(node, to: mixerNode, format: file.processingFormat)
                players[partInfo.part] = node
                files[partInfo.part] = file
            } catch {
                logger.error("stem decode failed \(partInfo.stemFile, privacy: .public): \(error)")
            }
        }
        engine = newEngine
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try newEngine.start()
            isEngineReady = true
            logger.notice("mixer engine started, lanes=\(self.players.count) (CPU log follows)")
        } catch {
            logger.error("engine start failed: \(error)")
            isEngineReady = false
        }
    }

    func teardown() {
        stopTicker()
        for node in players.values { node.stop() }
        engine?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        engine = nil
        players.removeAll()
        files.removeAll()
        isEngineReady = false
    }

    // MARK: - Transport

    func play() {
        prepare()
        guard isEngineReady else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        scheduleAll(from: transport.position_s)
        transport.state = .playing
        startTicker()
        updateNowPlaying()
        logger.notice("play @ \(self.transport.position_s)")
    }

    func pause() {
        transport.state = .paused
        // Freeze position: players stop (positions re-schedule on resume).
        for node in players.values { node.stop() }
        stopTicker()
        updateNowPlaying()
    }

    func seek(to seconds: Double) {
        transport.seek(to: seconds)
        if transport.state == .playing {
            scheduleAll(from: transport.position_s)
        }
        updateNowPlaying()
    }

    /// Arms an A/B region around the current position (drag-to-loop's audio
    /// counterpart; the notation entry point is UX A.2.4).
    func toggleLoopAroundCurrent() {
        if transport.loop != nil {
            transport.clearLoop()
        } else {
            let end = min(transport.position_s + 10, transport.duration_s)
            transport.setLoop(start_s: transport.position_s, end_s: end)
        }
        updateNowPlaying()
    }

    func tick() {
        transport.tick(dt: 0.1)
        if transport.state == .stopped {
            for node in players.values { node.stop() }
            stopTicker()
        }
    }

    // MARK: - Mixing (MixerModel values applied verbatim)

    /// Intent entry points: the view forwards intent, MixerModel decides,
    /// gains glide onto the player nodes. (MixerModel is a value type; the
    /// view must not mutate it through the private(set) getter.)

    func setFader(_ value: Double, for part: Part) {
        mixer.setFader(value, for: part)
        applyLaneGain(lane(for: part))
    }

    func setMuted(_ muted: Bool, for part: Part) {
        mixer.setMuted(muted, for: part)
        applyLaneGain(lane(for: part))
    }

    func setSoloed(_ soloed: Bool, for part: Part) {
        mixer.setSoloed(soloed, for: part)
        applyAllGains() // solo/mute of one lane changes OTHER lanes' gains too
    }

    func applyFocus(to target: Part?) {
        mixer.applyFocus(to: target)
        applyAllGains()
    }

    func applyAllVoices() {
        mixer.applyAllVoices()
        applyAllGains()
    }

    private func lane(for part: Part) -> MixerLane? {
        mixer.lanes.first { $0.part == part }
    }

    func applyLaneGain(_ lane: MixerLane?) {
        guard let lane, let node = players[lane.part] else { return }
        let target = mixer.resolvedGain(for: lane.part)
        let current = lastGainTargets[lane.part] ?? Double(node.volume)
        lastGainTargets[lane.part] = target
        // ~15 ms stepped glide (A.1.3): 8 × 2 ms via the deterministic envelope.
        let steps = MixerModel.glideSamples(from: current, to: target)
        for (index, value) in steps.enumerated() {
            let deadline = DispatchTime.now() + .milliseconds(index * 2)
            DispatchQueue.main.asyncAfter(deadline: deadline) { [weak node] in
                node?.volume = Float(value)
            }
        }
    }

    func applyAllGains() {
        for lane in mixer.lanes { applyLaneGain(lane) }
    }

    // MARK: - Scheduling (instant seek: precomputed files, frame offsets)

    private func scheduleAll(from position_s: Double) {
        for (part, node) in players {
            guard let file = files[part] else { continue }
            node.stop()
            let sampleRate = file.processingFormat.sampleRate
            let startFrame = AVAudioFramePosition(position_s * sampleRate)
            guard startFrame >= 0, startFrame < file.length else { continue }
            let remaining = AVAudioFrameCount(file.length - startFrame)
            node.scheduleSegment(file, startingFrame: startFrame, frameCount: remaining, at: nil) {
                // Segment played out (or stopped). On the loop path the next
                // segment is re-scheduled from the region start — the wrap
                // math lives in TransportModel; this keeps audio stable.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.transport.state == .playing,
                          let loop = self.transport.loop,
                          abs(self.transport.position_s - loop.upperBound) < 0.35 else { return }
                    self.scheduleAll(from: loop.lowerBound)
                }
            }
            node.play()
        }
    }

    // MARK: - Lock-screen transport (degrades without X-021)

    private func updateNowPlaying() {
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: song.manifest.title,
            MPNowPlayingInfoPropertyPlaybackRate: transport.state == .playing ? 1.0 : 0.0,
            MPMediaItemPropertyPlaybackDuration: transport.duration_s,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: transport.position_s,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let pos = event as? MPChangePlaybackPositionCommandEvent {
                Task { @MainActor in self?.seek(to: pos.positionTime) }
                return .success
            }
            return .commandFailed
        }
    }

    // MARK: - Ticker (UI position only; audio timing stays in AVFoundation)

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}
