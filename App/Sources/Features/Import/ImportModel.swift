import Foundation
import SwiftUI
import UniformTypeIdentifiers
import EngineCore
import PitchLogic

// ImportModel (J-201) — the import flow's state machine (UX §5.1, folded onto
// C-8's three stages): pick → setup → staged import (decode → separate →
// assemble) → done, with cooperative cancel and every error state from
// ImportFailure.cause. NEVER blocks the main thread: all engine + file work
// runs in the import Task; the main actor only receives progress snapshots
// and state transitions.
//
// Interruption safety: a cancelled or killed import leaves no partial bundle
// (engine removes staging per C-2.2); if iOS suspends the app mid-import the
// Task dies and the UI resets on relaunch — nothing partial ever appears.

@MainActor
final class ImportModel: ObservableObject {

    // MARK: - Phase

    enum Phase: Equatable {
        case idle
        /// Setup screen for the picked file (title prefill, size, format).
        case setup(SetupInfo)
        case running
        /// Cancel was tapped; the engine is finishing its cooperative unwind.
        case cancelling
        case completed(title: String)
        case failed(ImportError)
    }

    struct SetupInfo: Equatable {
        let url: URL
        let title: String
        let sizeBytes: Int64
        let formatLabel: String
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: ImportProgress?
    /// Wall-clock start of the running import (elapsed display; nil when idle).
    @Published private(set) var importStartedAt: Date?
    /// Engine-build honesty counters (C-8 violations observed at the UI).
    @Published private(set) var progressViolations: Int = 0
    @Published private(set) var thermalAdvice: ImportThermalGate.Advice = .none
    /// Recent imports (newest first; the "recent imports list" AC).
    @Published private(set) var recentRecords: [BundleRecord] = []
    /// True while the app is backgrounded mid-import (honest hint copy).
    @Published private(set) var importContinuesInBackground = false

    @Published var isImportPickerPresented = false
    /// Editable display title (prefilled from the filename at pick time).
    @Published var setupTitle = ""
    /// Which engine the LAST import ran on (J-208) — the import screen shows
    /// it, so a mock demo can never be mistaken for a real separation
    /// (D-12 honesty; Leto 21:55Z §1c: the M2 gate requires the REAL path).
    @Published private(set) var engineKind: ImportEngineKind = .mock
    /// What the NEXT import will do, BEFORE it runs (J-208, session 6): the
    /// real engine compiled in? the weights on the device? The demo script
    /// (UX §10.2 step 0) reads the badge BEFORE the import, so this must not
    /// wait for an import to have happened.
    @Published private(set) var availability: ImportEngineAvailability = .mockOnly
    /// The import-pass metrics of the LAST import (J-206): separation RTF,
    /// peak resident footprint, thermal start→end. nil until an import has
    /// run (never zeros — "not measured" must not read as "measured 0").
    @Published private(set) var metrics: ImportDeviceMetrics?
    /// The peak footprint seen SO FAR (live during the import).
    @Published private(set) var livePeakResidentBytes: UInt64?

    // FLAC has no static UTType member (UniformTypeIdentifiers ships
    // .mp3/.wav/.mpeg4Audio/.aiff); the system-declared UTI is org.xiph.flac,
    // which AVAudioFile decodes natively. .audio keeps the picker usable if
    // the identifier is ever unavailable.
    static let flac = UTType("org.xiph.flac") ?? .audio
    static let supportedTypes: [UTType] = [.mp3, flac, .wav, .mpeg4Audio, .aiff]

    private var store: BundleStore?
    private var importTask: Task<Void, Never>?
    private var tracker = ImportProgressTracker()
    private var scopedURL: URL?
    private var thermalObserver: NSObjectProtocol?
    /// The import-pass metrics collector (J-206) — samples the resident
    /// footprint while the import runs.
    private let metricsCollector = ImportMetricsCollector()
    /// The engine seam (J-208): the app resolves the REAL engine when it is
    /// compiled in and its weights are on disk; previews/tests inject the
    /// mock explicitly.
    private let engineFactory: ImportEngineFactory

    /// - Parameter engineFactory: nil = the shipping resolution (real engine
    ///   when available, mock otherwise — see `ImportEngineResolver`).
    init(engineFactory: ImportEngineFactory? = nil) {
        self.engineFactory = engineFactory
            ?? ImportEngineResolver.factory(modelURL: ModelCache.verifiedModelURL(named: "htdemucs"))
        refreshAvailability()
        Task.detached(priority: .userInitiated) { [weak self] in
            let store = try? BundleStore.makeDefault()
            await MainActor.run { [weak self] in
                self?.store = store
                self?.refreshRecentRecords()
            }
        }
        observeThermal()
    }

    /// Re-reads the engine availability (compile-time flag + the weights on
    /// disk). Called when the import screen appears — the human's path is
    /// Settings → Models (download) → Import, so the badge must catch up
    /// when they come back.
    func refreshAvailability() {
        let modelPresent = ModelCache.verifiedModelURL(named: "htdemucs") != nil
        availability = ImportEngineAvailability.resolve(
            compiledIn: RealEngineBuild.isCompiledIn,
            modelPresent: modelPresent)
    }

    deinit {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
    }

    // MARK: - Picker + setup

    func handlePickerResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            // Dismissing the picker is not an error (C-8 cancellation
            // semantics) — silently reset.
            if ImportFailure.cause(from: error) != .cancelled {
                phase = .failed(ImportFailure.cause(from: error))
            }
        case .success(let urls):
            guard let url = urls.first else { return }
            openSetup(for: url)
        }
    }

    func openSetup(for url: URL) {
        let gotScope = url.startAccessingSecurityScopedResource()
        scopedURL = gotScope ? url : nil // nil scope for app-container files is fine

        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
        phase = .setup(SetupInfo(
            url: url,
            title: url.deletingPathExtension().lastPathComponent,
            sizeBytes: size,
            formatLabel: ext.uppercased()))
        setupTitle = url.deletingPathExtension().lastPathComponent
        refreshThermalAdvice()
    }

    // MARK: - Import lifecycle

    func beginImport() {
        guard case .setup(let info) = phase, let store else { return }

        // Pre-flight: disk budget (fail BEFORE the long job, not at first
        // write). Volume query failure → proceed and let write errors surface.
        if let values = try? info.url.resourceValues(forKeys: [.volumeAvailableCapacityForOpportunisticUsageKey]),
           let available = values.volumeAvailableCapacityForOpportunisticUsage {
            if case .short(let needed, let avail) =
                ImportDiskBudget.verdict(sourceBytes: info.sizeBytes, availableBytes: available) {
                phase = .failed(.diskFull(neededBytes: needed, availableBytes: avail))
                stopSecurityScope()
                return
            }
        }

        tracker = ImportProgressTracker()
        progress = nil
        progressViolations = 0
        importStartedAt = Date()
        metrics = nil
        livePeakResidentBytes = nil
        // J-206: sample the resident footprint for the whole import; the
        // §8 budget is about the PEAK, not the last value.
        metricsCollector.start()
        phase = .running

        // The engine seam (J-208): the app never names a concrete engine at
        // the call site. The REAL engine (post paul→main) THROWS with an
        // actionable message when its weights are missing — it never falls
        // back to the mock silently (D-12 honesty).
        let handle: ImportEngineHandle
        do {
            handle = try engineFactory.makeEngine(bundleRoot: store.root)
        } catch {
            phase = .failed(ImportFailure.cause(from: error))
            stopSecurityScope()
            return
        }
        engineKind = handle.kind

        let sourceURL = info.url
        let title = setupTitle.isEmpty ? info.title : setupTitle

        importTask = Task { [weak self] in
            guard let self else { return }
            let engine = handle.engine
            engine.setImportProgressHandler { progress in
                // C-8: handler runs on an ARBITRARY queue — hop to main; the
                // tracker (pure) enforces monotonicity on ingest.
                Task { @MainActor [weak self] in
                    guard let self, case .running = self.phase else { return }
                    let enforced = self.tracker.feed(
                        stage: progress.stage, fraction: progress.fraction, detail: progress.detail)
                    self.progress = enforced
                    self.progressViolations =
                        self.tracker.clippedNonMonotonicEvents + self.tracker.rejectedEvents
                }
            }
            do {
                let audio = try await engine.importAudio(url: sourceURL)
                // J-206: the metrics cover the SEPARATION pass (the engine
                // work the §8 budget and the L-204 AC talk about): its wall
                // time, the source duration it separated, and the thermal
                // state at both ends of the pass.
                let thermalAtStart = ThermalLevelBridge.current
                let separationStartedAt = Date()
                let stems = try await engine.separate(audio, mode: .twoStem) // D-9: two-stem always
                let separationWallTime = Date().timeIntervalSince(separationStartedAt)
                let thermalAtEnd = ThermalLevelBridge.current
                let peakBytes = metricsCollector.stop()
                self.livePeakResidentBytes = peakBytes
                self.metrics = ImportDeviceMetrics(
                    separationWallTime_s: separationWallTime,
                    sourceDuration_s: audio.duration_s,
                    peakResidentBytes: peakBytes,
                    thermalAtStart: thermalAtStart,
                    thermalAtEnd: thermalAtEnd,
                    sourceDurationIsEstimate: handle.kind == .mock)

                // Post-separate bookkeeping OFF the main actor (file I/O):
                // consumer-rule completeness check (C-2.2) + index register.
                // C-9: prefer the producer's id; fall back to the rule-3
                // derivation from a stem URL (verified against song.json, the
                // completion marker — a half-written bundle is never
                // registered).
                let record = try await Task.detached(priority: .utility) { () -> BundleRecord in
                    let resolvedID = BundleIdentityResolver.resolveBundleID(
                        producerID: handle.bundleID(),
                        stems: stems,
                        bundleRoot: store.root)
                    guard let id = resolvedID,
                          store.isCompleteBundle(at: store.root.appendingPathComponent(id, isDirectory: true)) else {
                        throw EngineError.importFailed("completed bundle failed the completeness check")
                    }
                    let bookmark = try? sourceURL.bookmarkData()
                    return BundleRecord(
                        id: id,
                        title: title,
                        sourceFileName: sourceURL.lastPathComponent,
                        sourceBookmark: bookmark,
                        addedAt: Date(),
                        duration_s: audio.duration_s)
                }.value
                try await Task.detached(priority: .utility) {
                    try store.register(record)
                }.value

                self.tracker.finish(detail: "done")
                self.progress = self.tracker.snapshot
                self.phase = .completed(title: title)
                self.refreshRecentRecords()
                self.stopSecurityScope()
            } catch {
                // C-8: cancellation or error mid-import → staging removed by
                // the engine; NO partial bundle exists to clean up here.
                let cause = ImportFailure.cause(from: error)
                self.livePeakResidentBytes = self.metricsCollector.stop()
                self.phase = cause == .cancelled ? .idle : .failed(cause)
                self.stopSecurityScope()
            }
        }
    }

    /// [Cancel] — cooperative: cancels the Task; the engine throws
    /// CancellationError between chunks and removes its staging dir.
    func cancelImport() {
        guard case .running = phase else { return }
        phase = .cancelling
        importTask?.cancel()
    }

    /// Sheet dismissal / [OK] / [Done] — always resets to idle.
    func reset() {
        importTask?.cancel()
        importTask = nil
        tracker = ImportProgressTracker()
        progress = nil
        importStartedAt = nil
        livePeakResidentBytes = metricsCollector.stop()
        phase = .idle
        stopSecurityScope()
    }

    // MARK: - Scene phase (interruption safety)

    func scenePhaseChanged(_ scene: ScenePhase) {
        importContinuesInBackground = (scene == .background) && isImportInFlight
    }

    var isImportInFlight: Bool {
        switch phase {
        case .running, .cancelling: return true
        default: return false
        }
    }

    // MARK: - Thermal (AGENTS §8)

    private func observeThermal() {
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshThermalAdvice() }
        }
        refreshThermalAdvice()
    }

    private func refreshThermalAdvice() {
        thermalAdvice = ImportThermalGate.advice(for: ThermalLevelBridge.current)
    }

    // MARK: - Recent imports

    func refreshRecentRecords() {
        guard let store else { return }
        recentRecords = store.scan()
    }

    // MARK: - Security scope

    private func stopSecurityScope() {
        if let scopedURL {
            scopedURL.stopAccessingSecurityScopedResource()
            self.scopedURL = nil
        }
    }
}

/// Darwin bridge: ProcessInfo.thermalState → platform-neutral ThermalLevel
/// (the pure gate lives in PitchLogic; P-202's engine pacing consumes the same
/// levels).
enum ThermalLevelBridge {
    static var current: ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .fair
        }
    }
}
