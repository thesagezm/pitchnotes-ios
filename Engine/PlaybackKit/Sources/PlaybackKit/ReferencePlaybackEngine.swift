import Foundation
import AVFoundation
import EngineCore

// P-402 · The reference playback engine — sample-accurate stem sync, the
// seamless A/B loop, and the key/tempo shift that keeps grading aligned.
//
// WHAT THIS IS: the ENGINE-side player the learner session plays the
// reference through (Jess's MixerPlayer consumed a simpler per-node scheme in
// J-203; the learner session's contract is stricter — C-20). One lane per
// stem: AVAudioPlayerNode → AVAudioUnitTimePitch → the engine's main mixer.
//
// THE KEY/TEMPO SHIFT (C-20, via the ONE transform in EngineCore):
//   · KEY: `AVAudioUnitTimePitch.pitch` = transpositionSemitones × 100 CENTS.
//     `tuningCents` is NEVER applied here — D-22/C-20 §3: the AUDIO stays
//     byte-true, the grader offsets the REFERENCE (the composed grading
//     reference maps through `PlaybackTransform` so both sides move
//     TOGETHER).
//   · TEMPO: `AVAudioUnitTimePitch.rate` = tempoScale — TimePitch's rate is
//     PITCH-PRESERVED by construction, which is exactly why this engine uses
//     TimePitch and not AVAudioUnitVarispeed. The Varispeed fact (a plain
//     speed change imposes +12·log2(speed) semitones UP; the compensation is
//     −12·log2(speed), RESEARCH A.2.8) is MEASURED in
//     EngineCoreTests/VarispeedCompensationTests.swift — so if a future path
//     ever switches to Varispeed, the compensation it must apply is a
//     measured constant, not a folklore formula.
//   · The grading side consumes the SAME environment through
//     `PlaybackTransform` (EngineCore) — one semantic, never two (D-33).
//
// SAMPLE-ACCURATE SYNC: every lane schedules from the SAME frame offset in
// its own file (the stems are sample-aligned by construction — the separator
// wrote them from the same mix clock, C-2). The A/B loop is PRIMED, not
// re-scheduled: the wrap segment is queued on the node BEFORE the first
// segment finishes (AVAudioPlayerNode plays its queue back-to-back on one
// render timeline), so the seam is sample-accurate — no completion-callback
// race, no audible gap. The completion callback only re-primes the NEXT wrap.
//
// POSITION: `AVAudioPlayerNode.playerTime(forHostTime:)` anchored to the
// render timeline — the UI ribbon and the grader read this clock, not a
// wall-clock timer (the ticker stays UI-only). `offset_s` reports where the
// PLAYBACK is in BUNDLE time (untransposed): with rate = tempoScale, the
// node's sample position advances tempoScale× faster, so bundle time =
// sampleTime / (sampleRate × tempoScale) + regionStart − ... — the mapping is
// the transform's inverse, implemented ONCE here and verified against
// PlaybackTransform in the tests.

/// The configuration ONE lane plays under — the playback-side mirror of the
/// session's `PlaybackEnvironment` (C-20). The mapping FROM the environment
/// lives here, ONCE (the D-33 pattern); the tests verify it against
/// `PlaybackTransform`.
public struct PlaybackLaneConfig: Equatable, Sendable {

    /// The stem file's sample rate (the lane's node format).
    public let sampleRate: Double

    /// The session's key/tempo environment (C-20 §1/§5).
    public let environment: PlaybackEnvironment

    /// The `AVAudioUnitTimePitch.pitch` value: whole semitones × 100 CENTS.
    /// NEVER the recording's `tuningCents` (D-22: the audio is not retuned —
    /// the grading reference is).
    public var pitchCents: Float {
        Float(environment.transpositionSemitones * 100)
    }

    /// The `AVAudioUnitTimePitch.rate` value: the playback speed factor
    /// (pitch-preserved).
    public var rate: Float {
        Float(environment.tempoScale)
    }

    public init(sampleRate: Double, environment: PlaybackEnvironment) {
        self.sampleRate = sampleRate
        self.environment = environment
    }
}

/// One playable lane: a player node, a TimePitch node, its file, and the
/// loop-region scheduling state.
public final class PlaybackLane {

    public let part: Part
    public let node: AVAudioPlayerNode
    public let timePitch: AVAudioUnitTimePitch
    public let file: AVAudioFile
    /// The config the lane was BUILT with (the session environment snapshot).
    public let config: PlaybackLaneConfig

    init(part: Part, file: AVAudioFile, config: PlaybackLaneConfig) {
        self.part = part
        self.file = file
        self.config = config
        self.node = AVAudioPlayerNode()
        self.timePitch = AVAudioUnitTimePitch()
        self.timePitch.pitch = config.pitchCents
        self.timePitch.rate = config.rate
    }

    /// The lane's bundle-time position at `hostTime` (seconds in
    /// UNTRANSPOSED bundle time — what the ribbon, the roll and the grader
    /// all speak).
    ///
    /// THE UNIT FACT (pinned by the render tests): `AVAudioPlayerNode`'s
    /// `playerTime.sampleTime` counts the PLAYER's own output frames — the
    /// FILE frames it has consumed at the file's sample rate. TimePitch's
    /// rate makes the player render those frames FASTER or SLOWER in wall
    /// time, but never changes what a frame IS. So:
    ///   bundle time  = sampleTime / sampleRate                    (the song)
    ///   render time  = sampleTime / (sampleRate × tempoScale)     (the wall)
    public func bundleTime(at hostTime: UInt64) -> Double? {
        guard let nodeTime = node.playerTime(forHostTime: hostTime) else { return nil }
        return bundleTime(sampleTime: nodeTime.sampleTime)
    }

    /// The bundle-time (song) position for a node sample position.
    public func bundleTime(sampleTime: Double) -> Double {
        sampleTime / config.sampleRate
    }

    /// The render (wall) time for a node sample position — how long the
    /// playback has RUN, not where it is in the song.
    public func renderTime(sampleTime: Double) -> Double {
        sampleTime / (config.sampleRate * config.environment.tempoScale)
    }
}

/// The reference playback engine (P-402). One `AVAudioEngine`, one lane per
/// stem, one shared A/B loop region, one position clock.
public final class ReferencePlaybackEngine {

    /// A loop region in BUNDLE time (what the user dragged and what the
    /// grading reference speaks). Sample-accurate wrap math derives from it.
    public struct LoopRegion: Equatable, Sendable {
        public let start_s: Double
        public let end_s: Double
        public init(start_s: Double, end_s: Double) {
            self.start_s = start_s
            self.end_s = end_s
        }
    }

    private let engine = AVAudioEngine()
    private var lanes: [Part: PlaybackLane] = [:]
    private var laneOrder: [Part] = []
    private(set) var loop: LoopRegion?
    private(set) var isPlaying = false

    /// Build the lanes from the bundle's stem files under ONE session
    /// environment. Every lane gets the SAME environment (C-20 §1: the whole
    /// composed reference and the playback move together).
    /// - Throws: when a stem cannot be opened (the caller surfaces the real
    ///   error — the P-204 lesson: a failed prepare is never masked).
    public init(bundleStems: [Part: URL], environment: PlaybackEnvironment) throws {
        var sawRate: Double?
        for (part, url) in bundleStems {
            let file = try AVAudioFile(forReading: url)
            let rate = file.processingFormat.sampleRate
            // C-2.1/D-8: voice stems are 44.1 kHz mono (the instrumental may
            // be stereo). A mixed-rate bundle is a manifest lie — refused.
            if let existing = sawRate, existing != rate {
                throw PlaybackKitError.mixedSampleRates(existing, rate)
            }
            sawRate = rate
            let lane = PlaybackLane(part: part, file: file,
                                    config: PlaybackLaneConfig(sampleRate: rate,
                                                               environment: environment))
            engine.attach(lane.node)
            engine.connect(lane.node, to: lane.timePitch, format: file.processingFormat)
            engine.connect(lane.timePitch, to: engine.mainMixerNode,
                           format: file.processingFormat)
            lanes[part] = lane
            laneOrder.append(part)
        }
        guard !lanes.isEmpty else {
            throw PlaybackKitError.noStems
        }
    }

    /// The lanes, in build order.
    public var parts: [Part] { laneOrder }

    /// The lane for a part (the grader/ribbon reads positions through it).
    public func lane(for part: Part) -> PlaybackLane? { lanes[part] }

    /// THE TRANSFORM THE GRADING SIDE MUST USE — the ONE
    /// `PlaybackTransform` built from the SAME environment this engine plays
    /// under. The player and the grader cannot disagree: they construct from
    /// one value (D-33).
    public var transform: PlaybackTransform {
        PlaybackTransform(environment: firstLane?.config.environment ?? .neutral)
    }

    private var firstLane: PlaybackLane? { laneOrder.first.flatMap { lanes[$0] } }

    // MARK: - Transport

    /// Start the engine and schedule from `position_s` (bundle time).
    public func play(from position_s: Double) throws {
        if !engine.isRunning {
            try engine.start()
        }
        isPlaying = true
        scheduleAll(from: position_s)
        for part in laneOrder {
            lanes[part]?.node.play()
        }
    }

    /// Pause: nodes stop; positions re-schedule on resume (the J-203
    /// convention — stopping a node is instant, no glide artifacts).
    public func pause() {
        isPlaying = false
        for lane in lanes.values { lane.node.stop() }
    }

    /// Seek: re-schedule every lane at the SAME bundle frame offset.
    public func seek(to seconds: Double) throws {
        if isPlaying {
            try play(from: seconds)
        }
    }

    /// Arm the A/B region (bundle time). The NEXT schedule primes the wrap.
    public func setLoop(_ region: LoopRegion) {
        loop = region
    }

    public func clearLoop() {
        loop = nil
    }

    // MARK: - Scheduling (sample-accurate)

    /// Schedule every lane from `position_s` bundle time. WITH a loop
    /// region: the [position → loopEnd] segment is queued and the
    /// [loopStart → loopEnd] wrap is queued BEHIND it (sample-accurate
    /// back-to-back on one render timeline), so the seam is silent.
    /// WITHOUT a loop: one segment to the end of the file.
    private func scheduleAll(from position_s: Double) {
        for part in laneOrder {
            guard let lane = lanes[part] else { continue }
            lane.node.stop()
            let file = lane.file
            let sr = file.processingFormat.sampleRate

            // Bundle time → the file's own frame space. The stem advances in
            // REAL samples (rate is a render-side speedup, not a resample):
            // the file frame for bundle time t is t × sr — the rate maps
            // BUNDLE seconds to RENDER seconds, not to file frames.
            let startFrame = AVAudioFramePosition(max(0, position_s * sr))
            guard startFrame < file.length else { continue }

            if let loop = loop {
                let loopEndFrame = AVAudioFramePosition(min(loop.end_s, Double(file.length) / sr) * sr)
                let loopStartFrame = AVAudioFramePosition(max(0, loop.start_s * sr))
                guard startFrame < loopEndFrame else { continue }

                // Segment 1: [startFrame, loopEndFrame).
                let firstCount = AVAudioFrameCount(loopEndFrame - startFrame)
                let wrapCount = AVAudioFrameCount(loopEndFrame - loopStartFrame)
                guard wrapCount > 0 else { continue }

                lane.node.scheduleSegment(file, startingFrame: startFrame,
                                          frameCount: firstCount, at: nil)
                // THE PRIMED WRAP: queued behind segment 1 — the node plays
                // its queue back-to-back on one render timeline, so the
                // seam is sample-accurate (no callback race, no gap). Each
                // completion re-primes exactly one wrap.
                primeWrap(lane, from: loopStartFrame, count: wrapCount)
            } else {
                let remaining = AVAudioFrameCount(file.length - startFrame)
                lane.node.scheduleSegment(file, startingFrame: startFrame,
                                          frameCount: remaining, at: nil)
            }
        }
    }

    /// Queue ONE wrap pass; its completion queues the next one. The closure
    /// is the ONLY callback in the loop path — the segments themselves are
    /// already on the node's timeline when it starts playing.
    private func primeWrap(_ lane: PlaybackLane, from startFrame: AVAudioFramePosition,
                           count: AVAudioFrameCount) {
        lane.node.scheduleSegment(lane.file, startingFrame: startFrame,
                                  frameCount: count, at: nil) { [weak self, weak lane] in
            guard let self, let lane, self.isPlaying, self.loop != nil else { return }
            // The wrap just finished — prime the next pass.
            self.primeWrap(lane, from: startFrame, count: count)
        }
    }

    /// The engine's CURRENT bundle-time position (the position clock the
    /// ribbon/roll/grader read): the first lane's node time, mapped through
    /// the lane's bundle-time mapping. Sample-accurate and rate-aware.
    public func position(at hostTime: UInt64) -> Double? {
        firstLane?.bundleTime(at: hostTime)
    }
}

public enum PlaybackKitError: Error, Equatable {
    case noStems
    case mixedSampleRates(Double, Double)
}
