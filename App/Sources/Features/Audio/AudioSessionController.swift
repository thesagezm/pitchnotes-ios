import Foundation
import AVFoundation
import UIKit
import PitchLogic

// AudioSessionController (J-102) — AVAudioSession glue for the mic UX.
//
// Owns: permission state (via MicPermissionFlow, the tested PitchLogic
// machine), interruption handling (call / background), headphone route
// detection, and the input-level feed for the meter. The M1 level source is a
// MOCK (P-104 owns the real AVAudioEngine input tap; the protocol below is
// that swap seam — zero view changes when it lands).
//
// 100% local: this controller never touches the network; the Settings
// deep-link is the only "external" action and it is a system UI hop.

@MainActor
final class AudioSessionController: ObservableObject {

    // MARK: - Published state

    /// Permission + interruption machine (tested in logic-tests).
    @Published private(set) var flow = MicPermissionFlow()
    /// Headphone/bluetooth route present (banner guidance, UX J-102).
    @Published private(set) var hasHeadphones = true
    /// Normalized input level 0…1 for the meter (mock source in M1).
    @Published private(set) var inputLevel: Double = 0

    // MARK: - Level source seam (P-104 swaps the real tap in behind this)

    protocol MicLevelSource: AnyObject {
        func start(onLevel: @escaping (Double) -> Void)
        func stop()
    }

    /// M1 mock: deterministic 10 Hz level wobble — the meter's look and a11y
    /// behavior are real; the source is not. Replaced by P-104's engine tap.
    final class MockMicLevelSource: MicLevelSource {
        private var timer: Timer?

        func start(onLevel: @escaping (Double) -> Void) {
            stop()
            let start = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                let t = Date().timeIntervalSince(start)
                // Smooth wobble 0.25–0.75 (simulated singing dynamics).
                let level = 0.5 + 0.22 * sin(2.0 * .pi * 0.8 * t) + 0.05 * sin(2.0 * .pi * 3.1 * t)
                onLevel(min(max(level, 0), 1))
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }
    }

    private var levelSource: MicLevelSource = MockMicLevelSource()
    private var observers: [NSObjectProtocol] = []

    // MARK: - Permission

    /// Reads the CURRENT system permission (call on appear — the user may
    /// have toggled in Settings since launch).
    func refreshPermission() {
        let state: MicPermissionState
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: state = .granted
            case .denied: state = .denied
            default: state = .notDetermined
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted: state = .granted
            case .denied: state = .denied
            default: state = .notDetermined
            }
        }
        flow = MicPermissionFlow(permission: state)
    }

    /// The prompt flow: system dialog; deny lands on the Settings screen (AC:
    /// flows tested incl. deny — the state machine is unit-tested; this glue
    /// feeds it).
    func requestPermission() {
        let completion: (Bool) -> Void = { granted in
            Task { @MainActor in self.flow.requestResult(granted) }
        }
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: completion)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(completion)
        }
    }

    /// Denied state → Settings deep-link (iOS cannot re-prompt after deny).
    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Session observations (interruptions + route)

    func startObserving() {
        guard observers.isEmpty else { return }
        refreshPermission()
        refreshRoute()

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw ?? 0)
            Task { @MainActor in
                switch AVAudioSession.InterruptionType(rawValue: typeRaw ?? 0) {
                case .began:
                    self.flow.interruptionBegan()
                case .ended:
                    self.flow.interruptionEnded(shouldResume: options.contains(.shouldResume))
                default:
                    break
                }
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshRoute() }
        })
    }

    func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        levelSource.stop()
    }

    /// The current route's stable token (J-403's `routeID`): the output ports
    /// joined. A route change (headphones ↔ speaker ↔ Bluetooth) produces a
    /// DIFFERENT token, which stales the loopback calibration —
    /// LatencyResolver applies the honest zero and asks for a recalibration.
    static var currentRouteID: String? {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard !outputs.isEmpty else { return nil }
        return outputs.map { "\($0.portType.rawValue):\($0.name)" }.joined(separator: "|")
    }

    /// Headphones/bluetooth present? (speaker-mode guidance banner otherwise).
    func refreshRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        hasHeadphones = outputs.contains {
            [.headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP].contains($0.portType)
        }
    }

    /// Manual resume path for interruptions that ended without .shouldResume
    /// (real session activation is P-104; M1 only clears the machine).
    func resumeSession() {
        flow.interruptionEnded(shouldResume: true)
    }

    // MARK: - Level meter feed (mock in M1; P-104 real tap behind the protocol)

    func startLevelMeter() {
        levelSource.start { [weak self] level in
            Task { @MainActor in self?.inputLevel = level }
        }
    }

    func stopLevelMeter() {
        levelSource.stop()
        inputLevel = 0
    }
}
