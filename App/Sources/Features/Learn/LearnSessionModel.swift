import SwiftUI
import Combine
import PitchLogic
import EngineCore

// LearnSessionModel (J-402) — the learner session's runtime model: the UX
// §5.4 state machine (the PURE machine lives in PitchLogic and is
// unit-tested; this class drives it with real events and renders the phase).
//
// THE CONTRACT WIRING (all composed here, once, at session setup):
//   · the grading reference is the C-14 composition — the correction overlay
//     wins (CorrectionResolver), else the score-informed track, else the
//     heuristic track — and the session RECORDS which one graded
//     (`GradingReferenceInfo`);
//   · the latency offset is J-403's resolver output (manual wins; a loopback
//     is route-bound; uncalibrated is the honest zero) and goes into the
//     C-20 environment the grader consumes;
//   · the grading itself is J-401's `SessionGrader` (C-18 SessionResult out).
//
// THE AUDIO SEAM: the device layer (the mic pipeline P-104 feeds) calls
// `ingest(frame:)` per grading-grade frame (engine_id SWIFTF0, C-6.0). The
// DEMO path ingests a synthetic perfect-ish stream built from the composed
// reference (labelled DEMO — it is not a human singing, AGENTS §11).
//
// MAIN-THREAD RULE (the J-402 AC): frames arrive on the audio queue and are
// handed over non-blocking; grading runs detached and lands on the main
// actor once — the ribbon never blocks.

@MainActor
final class LearnSessionModel: ObservableObject {

    // MARK: Published session state

    @Published private(set) var phase: SessionPhase = .ready
    @Published private(set) var markers: [Int: SessionFeedback.Marker] = [:]
    @Published private(set) var phraseBanner: String?
    @Published private(set) var result: SessionResult?
    @Published private(set) var errorMessage: String?

    // The READY sheet's controls (§5.4).
    @Published var selectedPart: Part
    @Published var tolerancePreset: Int = 50      // ±50 / ±25 / ±10 (C-19 stops)
    @Published var octaveEquivalence: Bool = true
    @Published var countIn_beats: Int = 4         // 0 / 2 / 4 (C-19 bounds [0, 8])
    @Published private(set) var latencyBadge: LatencyResolver.Badge = .uncalibrated

    /// The machine (published via `phase`).
    private(set) var machine = SessionStateMachine()

    // MARK: The composed session facts

    let songTitle: String
    let bundleId: String
    let isDemo: Bool
    /// The engine's tracks (never mutated — C-11 rule 1).
    private let rawTracks: [Part: NoteTrack]
    private let bundleDirectory: URL?
    /// The manifest's `tuning_cents` (D-22) and the user's J-205 override —
    /// composed through TuningPolicy into the C-20 environment's tuningCents.
    private let detectedTuningCents: Int
    private let tuningOverride: TuningOverride?
    /// The C-14 composition, resolved once per run (retry re-resolves —
    /// UX §12.4: a correction made since the last attempt applies).
    private(set) var composed: [Part: NoteTrack] = [:]
    private(set) var gradingReference: GradingReferenceInfo =
        GradingReferenceInfo(source: .heuristic)
    private var resolvedLatency_ms: Int = 0

    /// The live frames of the CURRENT run (buffered from COUNT-IN too, per
    /// §5.4 — mic captured, not graded; the grader maps them by note span, so
    /// buffering early frames is harmless and keeps the stream contiguous).
    private var liveFrames: [PitchFrame] = []
    /// The reference timeline's zero, in live-clock time (the transport's
    /// start moment). Frame `t` values are live-clock seconds.
    var sessionLiveStart_s: Double = 0

    /// The metronome/count-in ticker (COUNT-IN only; 1 Hz = 1 beat).
    private var ticker: Timer?

    init(rawTracks: [Part: NoteTrack], bundleDirectory: URL?,
         title: String, bundleId: String, isDemo: Bool = false,
         detectedTuningCents: Int = 0, tuningOverride: TuningOverride? = nil) {
        self.rawTracks = rawTracks
        self.bundleDirectory = bundleDirectory
        self.songTitle = title
        self.bundleId = bundleId
        self.isDemo = isDemo
        self.detectedTuningCents = detectedTuningCents
        self.tuningOverride = tuningOverride
        // The first singable part (C-1 order) — the launcher's chip can move it.
        self.selectedPart = Part.allCases.filter(\.isSingableVoice)
            .first { rawTracks[$0] != nil } ?? .bass
        recompose()
        refreshLatency()
    }

    // MARK: The C-14 composition (overlay → score-informed → heuristic)

    /// Re-composes the grading reference for the selected part and records
    /// WHICH reference it is. Called at init and at every retry (a correction
    /// made since the last attempt applies — UX §12.4).
    func recompose() {
        guard rawTracks[selectedPart] != nil else {
            composed = [:]
            gradingReference = GradingReferenceInfo(source: .heuristic)
            return
        }
        // The overlay (C-14 case 1) when one exists on disk for this part.
        if let bundleDirectory {
            let store = CorrectionStore(bundleDirectory: bundleDirectory)
            if case let .loaded(loaded) = store.loadResult(),
               let overlay = loaded.partOverlays[selectedPart], !overlay.isEmpty {
                let effective = CorrectionResolver.resolve(raw: rawTracks,
                                                           overlays: loaded.partOverlays)
                composed = effective.tracks
                gradingReference = GradingReferenceInfo(.overlay)
                return
            }
        }
        // Cases 2/3: the score-informed decision belongs to the review the
        // user already made (J-304's `ScoreReview.reference`); the session
        // consumes its OUTCOME through the composed tracks the app holds —
        // the demo path has no score, so the heuristic track is the honest
        // reference and the UI says so.
        composed = rawTracks
        gradingReference = GradingReferenceInfo(source: .heuristic)
    }

    /// The latency badge + applied offset (J-403) for THIS session.
    func refreshLatency() {
        let stored = LatencyCalibration.load()
        let resolved = LatencyResolver.resolve(stored: stored,
                                               currentRouteID: AudioSessionController.currentRouteID)
        latencyBadge = resolved.badge
        resolvedLatency_ms = resolved.offset_ms
    }

    // MARK: The machine's user actions

    func start() {
        guard phase == .ready else { return }
        errorMessage = nil
        result = nil
        markers = [:]
        liveFrames = []
        recompose()
        refreshLatency()
        sessionLiveStart_s = ProcessInfo.processInfo.systemUptime
        machine.handle(.start(configuredCountIn_beats: countIn_beats))
        phase = machine.phase
        if machine.configuredCountIn_beats > 0 { startTicker() }
    }

    func pause() {
        machine.handle(.pause)
        phase = machine.phase
        stopTicker()
    }

    func resume() {
        machine.handle(.resume)
        phase = machine.phase
        if case .countIn = phase { startTicker() }
    }

    func restartPhrase() {
        machine.handle(.restartPhrase)
        phase = machine.phase
    }

    func quit() {
        machine.handle(.quit)
        phase = machine.phase
        stopTicker()
        // Discarded: no result, no history row. The discard is the honesty —
        // a session that never graded is never recorded as graded.
        result = nil
    }

    func retryWeakPhrases() {
        guard result != nil else { return }
        result = nil
        markers = [:]
        liveFrames = []
        recompose() // §12.4: the reference is re-read through C-14 at retry
        machine.handle(.retry(configuredCountIn_beats: countIn_beats))
        phase = machine.phase
        if machine.configuredCountIn_beats > 0 { startTicker() }
    }

    func retryAll() { retryWeakPhrases() }

    // MARK: The audio clock's events

    /// One metronome beat during COUNT-IN (the ticker's event).
    func countInBeatElapsed() {
        machine.handle(.countInBeatElapsed)
        phase = machine.phase
        if !phase.isLive || phase.isGradingActive { stopTicker() }
    }

    /// The last note ended and the 1 s tail elapsed (the transport's event).
    func tailElapsed() {
        machine.handle(.sessionTailElapsed)
        phase = machine.phase
        if phase == .done { grade() }
    }

    /// A live grading-grade frame from the mic pipeline (the audio queue's
    /// call; non-blocking — buffer + cheap marker math only).
    nonisolated func ingest(frame: PitchFrame) {
        Task { @MainActor in
            self.buffer(frame)
        }
    }

    private func buffer(_ frame: PitchFrame) {
        guard phase.isLive else { return }
        liveFrames.append(frame)
        // The real-time markers (§5.4): when a note's window closes, its dot
        // lands. Cheap: only the not-yet-marked notes are examined.
        let now = frame.t - sessionLiveStart_s
        let environment = SessionEnvironment(latencyOffset_ms: resolvedLatency_ms)
        let closed = SessionFeedback.closedNoteIndices(
            reference: composed[selectedPart] ?? NoteTrack(part: selectedPart, notes: []),
            environment: environment, atLiveTime_s: now)
        for index in closed where markers[index] == nil {
            let note = composed[selectedPart]?.notes.indices.contains(index) == true
                ? composed[selectedPart]!.notes[index] : nil
            guard let note else { continue }
            let inSpan = liveFrames.filter {
                let referenceT = environment.referenceTime(forLiveT: $0.t - sessionLiveStart_s)
                return referenceT >= note.start_s - 1e-9 && referenceT < note.end_s - 1e-9
            }
            markers[index] = SessionFeedback.marker(for: note, frames: inSpan,
                                                    environment: environment,
                                                    config: effectiveConfig)
        }
    }

    // MARK: The grade (J-401)

    /// The C-19 config this session grades against (the launcher's controls
    /// are the C-19 tunables; J-405's settings provide the defaults).
    var effectiveConfig: GradingConfig {
        GradingConfig(toleranceCents: tolerancePreset,
                      octaveEquivalence: octaveEquivalence)
    }

    /// Grades the buffered session (runs detached; the result lands on the
    /// main actor). Called when the machine reaches DONE.
    private func grade() {
        let reference = composed[selectedPart]
        let tuningCents = TuningPolicy.resolvedCents(detected: detectedTuningCents,
                                                     override: tuningOverride)
        let environment = SessionEnvironment(latencyOffset_ms: resolvedLatency_ms,
                                             tuningCents: tuningCents)
        let config = effectiveConfig
        let referenceInfo = gradingReference
        let frames = liveFrames
        let part = selectedPart
        let sessionId = UUID().uuidString
        let createdAt = ISO8601Timestamp.now()
        let id = bundleId
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try SessionGrader.grade(
                    reference: reference ?? NoteTrack(part: part, notes: []),
                    live: frames,
                    config: config,
                    environment: environment,
                    gradingReference: referenceInfo,
                    sessionId: sessionId,
                    bundleId: id,
                    createdAt: createdAt,
                    sessionStart_s: 0,
                    duration_s: nil)
                await MainActor.run {
                    self?.result = result
                }
            } catch {
                await MainActor.run {
                    self?.errorMessage = "The session could not be graded: \(error)"
                }
            }
        }
    }

    // MARK: The count-in ticker (1 Hz, COUNT-IN only)

    private func startTicker() {
        stopTicker()
        let ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.countInBeatElapsed() }
        }
        self.ticker = ticker
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    /// The weak phrases of the finished result (the results screen's queue).
    var weakPhrases: [PerPhraseResult] {
        guard let result else { return [] }
        return WeakPhrasePicker.phrases(in: result)
    }
}

// MARK: - Small helpers (device-local, deterministic)

enum ISO8601Timestamp {
    /// A fixed-format UTC timestamp (no locale, no clock skew in the format).
    static func now() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }
}
