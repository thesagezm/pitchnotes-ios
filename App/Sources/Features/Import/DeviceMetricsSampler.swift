import Foundation
import Darwin
import PitchLogic

// DeviceMetricsSampler (J-206) — the DEVICE half of the import-pass metrics.
//
// The seam: `ResidentFootprintSampling` is the only thing the import flow
// knows about; the Darwin implementation reads the app's own resident
// footprint through `task_info` (TASK_VM_INFO → phys_footprint), and a test
// fake can replace it. No Engine/ change, no contract change — the numbers
// are APP-SIDE observations of the app's own process (Leto, 23:00Z: "all
// three are measurable APP-SIDE with zero Engine/ changes").
//
// WHY phys_footprint and not ru_maxrss: `phys_footprint` is the memory the
// app ACTUALLY holds (the number iOS's jetsam uses); `ru_maxrss` is a peak
// watermark that includes memory the process no longer holds. The §8 budget
// ("peak RSS < 1.5 GB during separation") is about the live footprint.

/// The seam: something that can report the process's resident footprint.
protocol ResidentFootprintSampling: Sendable {
    /// Current resident footprint in bytes, or nil when it cannot be read.
    func currentResidentBytes() -> UInt64?
}

/// Reads the process's resident footprint via Darwin `task_info`.
struct DarwinTaskInfoSampler: ResidentFootprintSampling {

    func currentResidentBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }
}

/// Collects the metrics of ONE import pass: samples the footprint while the
/// import runs, records the thermal state at the start and end of the
/// separation, and times the separation itself.
@MainActor
final class ImportMetricsCollector {

    /// How often the footprint is sampled (0.5 s — frequent enough to catch a
    /// separation peak, cheap enough to ignore).
    static let sampleInterval: Duration = .milliseconds(500)

    private let sampler: ResidentFootprintSampling
    private var peak = PeakResidentTracker()
    private var samplingTask: Task<Void, Never>?

    /// The peak seen so far (nil until the first successful sample).
    private(set) var peakResidentBytes: UInt64?

    init(sampler: ResidentFootprintSampling = DarwinTaskInfoSampler()) {
        self.sampler = sampler
    }

    /// Start sampling. Called when the import starts.
    func start() {
        stop()
        peak = PeakResidentTracker()
        // The Task inherits this actor's isolation: the sampler call is a
        // single cheap syscall, twice a second — no reason to hop threads.
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let bytes = self.sampler.currentResidentBytes()
                self.peak.sample(bytes)
                self.peakResidentBytes = self.peak.peakBytes
                try? await Task.sleep(for: Self.sampleInterval)
            }
        }
    }

    /// Stop sampling and return the peak.
    func stop() -> UInt64? {
        samplingTask?.cancel()
        samplingTask = nil
        return peak.peakBytes
    }
}
