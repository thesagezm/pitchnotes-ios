import Foundation
import EngineCore

// MixerModel (J-203) — the stem mixer's PURE logic: lanes, presets, gains,
// glides, transport. Unit-tested here; the AVAudioEngine path (App layer)
// consumes these values verbatim so the behavior is identical in CI tests,
// on device, and after the P-204 real-engine swap (zero logic changes).
//
// D-12 bleed honesty: the FOCUS preset attenuates other lanes (default
// −12 dB ≈ 25% fader) and never hard-mutes — separated stems bleed, so a
// "solo"-labeled focus would lie. An EXPLICIT user solo is honest (labeled
// as muting the other lanes); the focus preset is not.

/// One mixer lane (one stem = one Part entry in the manifest, C-2.2).
public struct MixerLane: Identifiable, Codable, Equatable, Sendable {
    public var part: Part
    /// UI fader position 0…1 (linear amplitude ratio; dB = 20·log10(fader)).
    public var fader: Double
    public var isMuted: Bool
    public var isSoloed: Bool

    public var id: String { part.rawValue }

    public init(part: Part, fader: Double = 1.0, isMuted: Bool = false, isSoloed: Bool = false) {
        self.part = part
        self.fader = min(max(fader, 0), 1)
        self.isMuted = isMuted
        self.isSoloed = isSoloed
    }
}

public enum MixerPreset: String, CaseIterable, Sendable, Identifiable {
    /// Default (D-12): target lane unity, every other lane −12 dB.
    case focus
    /// All lanes unity.
    case allVoices
    /// User has moved a fader — the custom state (no preset highlighted).
    case custom

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .focus: return "Focus"
        case .allVoices: return "All voices"
        case .custom: return "Custom"
        }
    }
}

/// Pure mixer state + resolution. Sendable struct: the view layer owns a
/// copy and applies resolved linear gains to player nodes.
public struct MixerModel: Equatable, Sendable {

    /// Focus preset attenuation for non-target lanes (UX §5.3, AGENTS honest-mix rule).
    public static let focusAttenuationDB: Double = -12
    /// The fader position that equals −12 dB (20·log10(x) = −12 → x ≈ 0.25).
    public static let focusFaderPosition: Double = pow(10.0, focusAttenuationDB / 20.0)

    public private(set) var lanes: [MixerLane]
    public private(set) var preset: MixerPreset = .focus
    /// The lane focus applies to (nil = all-voices focus → no attenuation).
    public private(set) var focusTarget: Part?

    /// Lanes follow the manifest's parts[] — D-9: NO INSTRUMENTAL lane when
    /// `hasInstrumental == false`. Order = manifest order (C-2.2).
    public init(parts: [Part], focusTarget: Part? = nil) {
        self.lanes = parts.map { MixerLane(part: $0) }
        self.focusTarget = focusTarget
        applyFocus()
    }

    // MARK: - Presets

    /// Applies the focus preset (DEFAULT on open): target unity, others
    /// −12 dB, no mutes/solos. Bleed-honest — never hard-mutes (D-12).
    public mutating func applyFocus(to target: Part?) {
        focusTarget = target
        let hasTarget = target != nil
        for index in lanes.indices {
            lanes[index].isMuted = false
            lanes[index].isSoloed = false
            lanes[index].fader = (hasTarget && lanes[index].part == target)
                ? 1.0 : (hasTarget ? Self.focusFaderPosition : 1.0)
        }
        preset = .focus
    }

    /// All voices unity (and instrumental lane if present — it IS a lane).
    public mutating func applyAllVoices() {
        focusTarget = nil
        for index in lanes.indices {
            lanes[index].isMuted = false
            lanes[index].isSoloed = false
            lanes[index].fader = 1.0
        }
        preset = .allVoices
    }

    public mutating func setFader(_ value: Double, for part: Part) {
        if let index = lanes.firstIndex(where: { $0.part == part }) {
            lanes[index].fader = min(max(value, 0), 1)
            lanes[index].isMuted = false
            preset = .custom
        }
    }

    public mutating func setMuted(_ muted: Bool, for part: Part) {
        if let index = lanes.firstIndex(where: { $0.part == part }) {
            lanes[index].isMuted = muted
            if muted { lanes[index].isSoloed = false }
            preset = .custom
        }
    }

    /// EXPLICIT solo: soloed lanes play, ALL other lanes hard-mute. Honest
    /// labeling duty is on the UI ("mutes the other lanes — stems still
    /// bleed into the soloed lane"). Multiple solos = union of soloed lanes.
    public mutating func setSoloed(_ soloed: Bool, for part: Part) {
        if let index = lanes.firstIndex(where: { $0.part == part }) {
            lanes[index].isSoloed = soloed
            if soloed { lanes[index].isMuted = false }
            preset = .custom
        }
    }

    // MARK: - Gain resolution

    /// The linear amplitude gain ONE lane renders at right now.
    /// Solo active anywhere → non-soloed lanes are 0 (explicit-solo honesty).
    /// Otherwise mute → 0; else the fader position.
    public func resolvedGain(for part: Part) -> Double {
        let anySolo = lanes.contains { $0.isSoloed }
        guard let lane = lanes.first(where: { $0.part == part }) else { return 0 }
        if anySolo {
            return lane.isSoloed ? lane.fader : 0
        }
        return lane.isMuted ? 0 : lane.fader
    }

    /// dB readout for a lane's resolved gain (−∞ rendered as "muted" upstream).
    public func resolvedGainDB(for part: Part) -> Double {
        let gain = resolvedGain(for: part)
        return gain <= 0 ? -.infinity : 20.0 * log10(gain)
    }

    // MARK: - Glide (no zipper noise)

    /// Linear gain glide samples for ONE lane change (UX §11 A.1.3): ~15 ms
    /// stepped ramp, applied by the audio layer between renders. Steps are
    /// ~2 ms apart (audio-thread friendly); count is deterministic so tests
    /// and the node agree.
    public static func glideSamples(from: Double, to: Double, durationMS: Double = 15,
                                    stepMS: Double = 2) -> [Double] {
        let steps = max(1, Int((durationMS / stepMS).rounded()))
        return (1...steps).map { fraction in
            let t = Double(fraction) / Double(steps)
            return from + (to - from) * t
        }
    }
}

// MARK: - Transport (pure; the audio layer schedules, this decides)

public enum TransportState: Equatable, Sendable {
    case stopped
    case playing
    case paused
}

/// Region loop + position math (J-203 AC "seek/loop stable").
public struct TransportModel: Equatable, Sendable {
    public var state: TransportState = .stopped
    /// Song position in seconds (the audio layer's source of truth; this
    /// mirrors it for UI display and decides loop wraps).
    public var position_s: Double = 0
    public var duration_s: Double
    /// Region loop (A/B); nil = off. start < end, clamped to the duration.
    public var loop: ClosedRange<Double>?

    public init(duration_s: Double) {
        self.duration_s = max(duration_s, 0)
    }

    public mutating func setLoop(start_s: Double, end_s: Double) {
        guard end_s - start_s >= 0.5 else { return } // degenerate drags = no loop
        let lo = min(max(start_s, 0), duration_s)
        let hi = min(max(end_s, 0), duration_s)
        loop = min(lo, hi)...max(lo, hi)
        // Seeking into the region arms it immediately.
        if let loop, !loop.contains(position_s) {
            position_s = loop.lowerBound
        }
    }

    public mutating func clearLoop() {
        loop = nil
    }

    /// Advances playback position (called per UI tick with wall-clock dt).
    /// Loop wrap: crossing `loop.upperBound` restarts at `lowerBound` —
    /// positions NEVER leave the region while a loop is armed (stable loop).
    public mutating func tick(dt: Double) {
        guard state == .playing else { return }
        position_s += dt
        if let loop {
            if position_s >= loop.upperBound || position_s < loop.lowerBound {
                position_s = loop.lowerBound + (position_s - loop.upperBound)
                    .truncatingRemainder(dividingBy: loop.length)
            }
        } else if position_s >= duration_s {
            position_s = duration_s
            state = .stopped
        }
    }

    public mutating func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), duration_s)
        position_s = clamped
        if let loop, !loop.contains(clamped) {
            // Seeking outside the region releases the loop (predictable).
            loop = nil
        }
    }
}

private extension ClosedRange where Bound == Double {
    var length: Double { upperBound - lowerBound }
}
