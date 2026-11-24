import Foundation

// ImportDeviceMetrics (J-206) — the PURE half of the import-pass metrics.
//
// What the M2 gate needs (L-204 AC "RSS/thermal/RTF from device" + the
// human's P-603 ask) and what §8 budgets:
//
//   · SEPARATION WALL TIME — how long the separation pass took;
//   · SOURCE DURATION — the length of the audio that was separated;
//   · RTF (real-time factor) = separation wall time ÷ source duration.
//     RTF < 1.0 means the separation ran faster than the song plays;
//   · PEAK RESIDENT FOOTPRINT — the highest memory the app held during the
//     import (the §8 budget: peak RSS < 1.5 GB during separation);
//   · THERMAL STATE at the start and at the end of the pass (the §8 pacing
//     rule: pace work against `ProcessInfo.thermalState`).
//
// Everything here is arithmetic and formatting — the sampling itself lives in
// the App layer behind a seam (Darwin `task_info` phys_footprint), so the
// numbers can be unit-tested without a device.
//
// HONESTY (D-12): an unsampled value is reported as "not sampled", never as
// zero. A missing RTF is "—", never "0.00×" (which would read as "infinitely
// fast"). The source duration of the MOCK engine is an ESTIMATE and says so.

/// The metrics of one import pass.
public struct ImportDeviceMetrics: Equatable, Sendable {

    /// Wall time of the separation pass (seconds).
    public var separationWallTime_s: Double
    /// Duration of the separated audio (seconds). For the mock engine this is
    /// an ESTIMATE derived from the file size — the UI labels it.
    public var sourceDuration_s: Double
    /// Peak resident footprint during the import (bytes); nil when the
    /// sampler was unavailable (never 0 — 0 would read as "no memory used").
    public var peakResidentBytes: UInt64?
    /// Thermal state when the separation started.
    public var thermalAtStart: ThermalLevel
    /// Thermal state when the separation ended.
    public var thermalAtEnd: ThermalLevel
    /// Whether the source duration is a real measurement or the mock's
    /// size-based estimate (the UI says "estimated" when true).
    public var sourceDurationIsEstimate: Bool

    public init(
        separationWallTime_s: Double,
        sourceDuration_s: Double,
        peakResidentBytes: UInt64?,
        thermalAtStart: ThermalLevel,
        thermalAtEnd: ThermalLevel,
        sourceDurationIsEstimate: Bool = false
    ) {
        self.separationWallTime_s = separationWallTime_s
        self.sourceDuration_s = sourceDuration_s
        self.peakResidentBytes = peakResidentBytes
        self.thermalAtStart = thermalAtStart
        self.thermalAtEnd = thermalAtEnd
        self.sourceDurationIsEstimate = sourceDurationIsEstimate
    }

    /// RTF = separation wall time ÷ source duration. nil when the source
    /// duration is unknown or zero (never a clamped guess).
    public var realtimeFactor: Double? {
        guard sourceDuration_s > 0 else { return nil }
        return separationWallTime_s / sourceDuration_s
    }
}

/// Tracks the PEAK of a sampled series (the memory number the §8 budget is
/// about is the peak, not the last value).
public struct PeakResidentTracker: Equatable, Sendable {

    public private(set) var peakBytes: UInt64?

    public init() {}

    /// Feed one sample; keeps the maximum.
    public mutating func sample(_ bytes: UInt64?) {
        guard let bytes else { return }
        if let current = peakBytes {
            peakBytes = max(current, bytes)
        } else {
            peakBytes = bytes
        }
    }
}

/// Honest formatting for the import screen and the demo script (the numbers
/// the human writes into the QUEUE LOG for BENCHMARKS §6).
public enum ImportMetricsFormatter {

    /// "0.42×" — or "—" when there is no RTF to report.
    public static func realtimeFactor(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return String(format: "%.2f×", value)
    }

    /// "512 MB" — or "not sampled" when the sampler had nothing.
    public static func residentBytes(_ bytes: UInt64?) -> String {
        guard let bytes else { return "not sampled" }
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.2f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }

    /// Seconds as "1:23" (wall times are read in minutes and seconds).
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The one-line summary the demo script copies verbatim.
    public static func summary(_ metrics: ImportDeviceMetrics) -> String {
        let rtf = realtimeFactor(metrics.realtimeFactor)
        let peak = residentBytes(metrics.peakResidentBytes)
        let wall = duration(metrics.separationWallTime_s)
        let source = duration(metrics.sourceDuration_s)
        let estimate = metrics.sourceDurationIsEstimate ? " (estimated)" : ""
        return "Separation \(wall) for \(source)\(estimate) source → RTF \(rtf) · peak RSS \(peak) · thermal \(metrics.thermalAtStart.label)→\(metrics.thermalAtEnd.label)"
    }
}

extension ThermalLevel {
    /// Short, honest label for the metrics line.
    public var label: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        }
    }
}
