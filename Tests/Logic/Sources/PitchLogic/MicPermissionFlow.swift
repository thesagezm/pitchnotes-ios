// MicPermissionFlow — PURE state machine behind J-102 (mic permission + audio
// session UX). The AVAudioSession glue (App lane) feeds it events; the UI
// renders its `gate`. Foundation-only so the flows are unit-tested in
// logic-tests (AC: "permission flows tested incl. deny").
//
// Gate precedence: a DENIED permission always shows the Settings screen
// (deepest problem first); an interruption banner only matters once permission
// is granted. No timers, no I/O — deterministic and portable.

import Foundation

/// Microphone permission as iOS reports it.
public enum MicPermissionState: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
}

/// What the audio-UX layer should show right now.
public enum MicSessionGate: Equatable, Sendable {
    /// Prompt the user ("Enable microphone") — notDetermined.
    case askPermission
    /// Denied → Settings deep-link screen (no crash, no re-prompt possible).
    case deniedSettings
    /// Granted but session interrupted (call / background) → paused banner.
    case interrupted
    /// Ready for live input.
    case ready
}

public struct MicPermissionFlow: Equatable, Sendable {

    public private(set) var permission: MicPermissionState
    public private(set) var interrupted = false
    /// True when the last interruption ended with .shouldResume (auto-resume
    /// is safe); false = user must restart manually (rare path).
    public private(set) var shouldResumeAfterInterruption = false

    public init(permission: MicPermissionState = .notDetermined) {
        self.permission = permission
    }

    /// System answered the permission request (deny included — no crash, just
    /// the Settings screen).
    public mutating func requestResult(_ granted: Bool) {
        guard permission == .notDetermined else { return }
        permission = granted ? .granted : .denied
    }

    /// AVAudioSession .interruptionNotification .began (phone call, Siri…).
    public mutating func interruptionBegan() {
        interrupted = true
        shouldResumeAfterInterruption = false
    }

    /// .interruptionNotification .ended — `shouldResume` mirrors the
    /// AVAudioSession.InterruptionOptions.shouldResume option.
    public mutating func interruptionEnded(shouldResume: Bool) {
        interrupted = false
        shouldResumeAfterInterruption = shouldResume
    }

    public var gate: MicSessionGate {
        switch permission {
        case .notDetermined: return .askPermission
        case .denied: return .deniedSettings
        case .granted:
            return interrupted ? .interrupted : .ready
        }
    }
}
