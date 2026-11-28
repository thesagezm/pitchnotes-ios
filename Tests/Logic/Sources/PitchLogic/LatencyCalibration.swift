import Foundation

// J-403 · Latency compensation — the device-local calibration (C-20 §4).
//
// WHAT THIS IS: the offset that makes grading alignment honest on real
// hardware. Sound leaves the speaker, crosses the air (or a Bluetooth codec),
// reaches the mic, and is processed — the frame captured at `t` describes the
// singer's voice from EARLIER. The grader already consumes the offset with
// the contract's sign (SessionGraderTimingTests pins it); THIS file produces,
// stores, and resolves that offset.
//
// THE SIGN (C-20 §4, pinned): `offset_ms ≥ 0` means the live path is LATE by
// that much — the grader compares the frame at `t` against the reference at
// `t − latencyOffset_ms`. The loopback measures exactly this quantity: the
// click is emitted at `E`, the mic hears it at `D`, and the offset is `D − E`.
//
// THE TWO SOURCES:
//   · LOOPBACK — measured on THIS device's current route (play a click →
//     detect the onset → offset). Stale the moment the route changes
//     (headphones ↔ speaker ↔ Bluetooth have different latencies), so the
//     resolver STALES it on a route mismatch: the session applies 0 and says
//     why — never a stale number silently applied.
//   · MANUAL — the user's slider. It persists per device ACROSS routes (the
//     user set it, the user owns it) and wins over any loopback measurement
//     (UX §12.3: "a manual slider always wins").
//
// WHERE IT LIVES: `UserDefaults`, one key, per app install — the
// DeviceCalibration precedent. NEVER in the SongBundle (C-20 §4: the offset's
// home is device-local; a session records only the value APPLIED, C-18).

/// The device's stored latency calibration.
public struct LatencyCalibration: Codable, Equatable, Sendable {

    /// Where the offset came from (C-20 §4's device-local home; the sources
    /// are this module's vocabulary, not contract raw values).
    public enum Source: String, Codable, Sendable {
        case loopback
        case manual
    }

    /// The C-20 §4 sign: ≥ 0 = the live path is LATE by this much.
    public var offset_ms: Int
    public var source: Source
    /// The audio route the calibration was measured or set on (the device
    /// layer's route token — AVAudioSession's route description). A route
    /// change STALES a loopback calibration; a manual one persists.
    public var routeID: String?
    /// ISO-8601 UTC, caller-supplied (logic never reads the clock).
    public var updatedAt: String?

    public init(offset_ms: Int, source: Source,
                routeID: String? = nil, updatedAt: String? = nil) {
        self.offset_ms = offset_ms
        self.source = source
        self.routeID = routeID
        self.updatedAt = updatedAt
    }
}

// MARK: - The loopback measurement core

/// One loopback round trip. THE SEAM: the device layer (J-402's session audio)
/// emits a click at `emittedAt_s` on the OUTPUT timeline and reports when the
/// INPUT tap heard it (`detectedAt_s`, the same clock). This type is all the
/// calibration logic needs — the AVAudioEngine half is device work with a
/// test fake here.
public struct LoopbackMeasurement: Equatable, Sendable {
    public let emittedAt_s: Double
    public let detectedAt_s: Double

    public init(emittedAt_s: Double, detectedAt_s: Double) {
        self.emittedAt_s = emittedAt_s
        self.detectedAt_s = detectedAt_s
    }

    /// This round's offset (C-20 §4's sign: detected later ⇒ positive ⇒
    /// live is late).
    public var offset_ms: Int {
        Int(((detectedAt_s - emittedAt_s) * 1000).rounded())
    }
}

public enum LoopbackCalibrator {

    /// The rounds per calibration (odd — the median survives a dropped
    /// or double-triggered round).
    public static let rounds = 5
    /// A round farther than this from the current median is an outlier (a
    /// missed/double click, a route glitch): EXCLUDED and reported, never
    /// averaged in.
    public static let outlierTolerance_ms = 40
    /// The plausible hardware window for `D − E` (air + BT codec + DSP).
    /// A median outside it is REFUSED — a "calibration" of 4 seconds is not
    /// a calibration, it is a bug wearing one's clothes.
    public static let plausibleRange_ms = -50...250

    public enum CalibrationError: Error, Equatable {
        case notEnoughCleanRounds(got: Int, need: Int)
        case implausibleMedian(Int)
    }

    /// The calibration from the loopback rounds: the MEDIAN of the clean
    /// rounds (robust to outliers), checked against the plausible window.
    ///
    /// The AC's ±10 ms: with clean synthetic rounds the median IS the planted
    /// offset exactly — the median (not the mean) is what keeps a glitchy
    /// round from shifting the result.
    public static func calibrate(_ measurements: [LoopbackMeasurement],
                                 routeID: String?, updatedAt: String?) throws -> LatencyCalibration {
        let offsets = measurements.map(\.offset_ms).sorted()
        guard !offsets.isEmpty else {
            throw CalibrationError.notEnoughCleanRounds(got: 0, need: 1)
        }

        // The median, then the outlier pass (one iteration: a round farther
        // than `outlierTolerance_ms` from the median is dropped).
        var median = offsets[offsets.count / 2]
        let kept = offsets.filter { abs($0 - median) <= outlierTolerance_ms }
        if kept.count < offsets.count {
            guard !kept.isEmpty else {
                throw CalibrationError.notEnoughCleanRounds(got: 0, need: 1)
            }
            median = kept[kept.count / 2]
        }
        guard kept.count >= 1, measurements.count >= 1 else {
            throw CalibrationError.notEnoughCleanRounds(got: kept.count, need: 1)
        }

        guard plausibleRange_ms.contains(median) else {
            throw CalibrationError.implausibleMedian(median)
        }
        return LatencyCalibration(offset_ms: median, source: .loopback,
                                  routeID: routeID, updatedAt: updatedAt)
    }

    /// The outlier report for the UI (which rounds were excluded and why) —
    /// the honest calibration screen shows the rounds, not just the number.
    public static func outliers(in measurements: [LoopbackMeasurement]) -> (kept: [Int], excluded: [Int]) {
        let offsets = measurements.map(\.offset_ms)
        guard !offsets.isEmpty else { return ([], []) }
        let median = offsets.sorted()[offsets.count / 2]
        var kept: [Int] = []
        var excluded: [Int] = []
        for offset in offsets {
            if abs(offset - median) <= outlierTolerance_ms {
                kept.append(offset)
            } else {
                excluded.append(offset)
            }
        }
        return (kept, excluded)
    }
}

// MARK: - The resolver (what the session APPLIES)

public enum LatencyResolver {

    /// Why this session has this offset — the badge the session screen shows
    /// (UX §12.3: calibrated / manual / route-changed / uncalibrated).
    public enum Badge: Equatable, Sendable {
        /// Measured on THIS route — applied.
        case calibrated(Int)
        /// The user's slider — applied, wins over everything.
        case manual(Int)
        /// A loopback measured on a DIFFERENT route — NOT applied (0), the
        /// user is told to recalibrate. Never a stale number silently used.
        case routeChanged(Int)
        /// No calibration on this device — 0, honestly.
        case uncalibrated

        public var offset_ms: Int {
            switch self {
            case .calibrated(let o), .manual(let o), .routeChanged(let o): return o
            case .uncalibrated: return 0
            }
        }

        /// The APPLIED offset (routeChanged/uncalibrated apply 0 — C-20 §4:
        /// the session records the value APPLIED).
        public var appliedOffset_ms: Int {
            switch self {
            case .calibrated(let o), .manual(let o): return o
            case .routeChanged, .uncalibrated: return 0
            }
        }

        public var label: String {
            switch self {
            case .calibrated(let o): return "calibrated (+\(o) ms on this route)"
            case .manual(let o): return "manual (+\(o) ms)"
            case .routeChanged(let o): return "route changed — the +\(o) ms measurement was for another output; recalibrate"
            case .uncalibrated: return "not calibrated — grading assumes no delay"
            }
        }
    }

    /// The APPLIED offset + the badge for the current session.
    ///
    /// THE RULES: manual wins (UX §12.3); loopback applies only on its own
    /// route; a stale or absent calibration applies 0 — the honest zero, not
    /// a plausible-looking stale number.
    public static func resolve(stored: LatencyCalibration?,
                               currentRouteID: String?) -> (offset_ms: Int, badge: Badge) {
        guard let stored else { return (0, .uncalibrated) }
        switch stored.source {
        case .manual:
            return (stored.offset_ms, .manual(stored.offset_ms))
        case .loopback:
            if stored.routeID == currentRouteID {
                return (stored.offset_ms, .calibrated(stored.offset_ms))
            }
            return (0, .routeChanged(stored.offset_ms))
        }
    }
}

// MARK: - Persistence (the device's own store — the DeviceCalibration pattern)

public extension LatencyCalibration {

    /// The `UserDefaults` key the calibration lives under.
    static let defaultsKey = "deviceCalibration.latency"

    /// Reads the calibration from the device's defaults.
    ///
    /// A missing key ⇒ nil (uncalibrated — the absence rule: an unset device
    /// behaves exactly as "no calibration" should). A value that does not
    /// decode ⇒ nil, never a crash.
    static func load(from defaults: UserDefaults = .standard) -> LatencyCalibration? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(LatencyCalibration.self, from: data)
    }

    /// Writes the calibration to the device's defaults (atomic, one key).
    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: LatencyCalibration.defaultsKey)
        }
    }

    /// Removes the calibration (the slider's "reset" action).
    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
