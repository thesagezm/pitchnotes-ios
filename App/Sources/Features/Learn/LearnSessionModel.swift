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
// THE SESSION CLOCK (the J-402 wire-in): a `SessionFrameProducing` source
// stamps frames on the SESSION-LOCAL grid (t = 0 at run start, frozen on
// pause); the reference begins at t = countIn_s (beats are 1 s — the ticker's
// convention). The model translates frames to REFERENCE-ALIGNED time at
// ingest — exactly once, here — so the pure machine, the markers and the
// grader all share one clock (the C-20 latency mapping applies on top).
//
// THE DEMO PATH renders DemoSinger's synthetic stream (labelled DEMO at
// every UI surface — it is not a human singer, AGENTS §11). THE REAL PATH
// consumes the C-6.0 causal ribbon behind `RibbonSessionFrameProducer`;
// P-401's aligned SwiftF0 batch becomes the grade input at `grade()`'s
// documented seam when it lands (zero model/UI change).
//
// MAIN-THREAD RULE (the J-402 AC): frames arrive on the audio queue and are
// handed over non-blocking; grading runs detached and lands on the main
// actor once — the ribbon never blocks.

@MainActor
final class LearnSessionModel: ObservableObject {

    /// The §5.4 tail: the session ends this long after the last note ends.
    static let tail_s = 1.0

    // MARK: Published session state

    @Published private(set) var phase: SessionPhase = .ready
    @Published private(set) var markers: [Int: SessionFeedback.Marker] = [:]
    @Published private(set) var phraseBanner: String?
    @Published private(set) var result: SessionResult?
    @Published private(set) var errorMessage: String?
    /// An interruption (call/backgrounding) paused this session — the banner
    /// says so; the user resumes explicitly.
    @Published private(set) var pausedByInterruption = false

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

    /// The live frames of the CURRENT run, reference-aligned (t = 0 at the
    /// reference's start; the count-in offset was removed at ingest).
    private var liveFrames: [PitchFrame] = []
    /// The newest ingested frame's reference-aligned time (the restart-phrase
    /// rewind target). nil while no frame has arrived (e.g. no mic).
    private var latestFrameT_s: Double?

    // The run's clock facts (re-derived per run — start AND retry).
    private var countInDuration_s: Double = 0
    private var referenceEnd_s: Double = 0
    private var tailFired = false
    /// The ticker's ACTIVE-phase seconds (frozen on pause — the session clock).
    private var activeSeconds = 0

    /// The live-frame source of the current run (demo synth or the real
    /// ribbon). nil until start/retry arms it, or when the mic failed.
    private var frameProducer: SessionFrameProducing?
    /// Interruption/route observers (J-102's controller reused for its
    /// notification glue; a session model owning one is cheap and confined).
    private let sessionAudio = AudioSessionController()
    /// The 1 Hz session ticker: count-in beats during COUNT-IN, the tail
    /// deadline check during ACTIVE. Paused with the session.
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

    /// The C-20 environment every consumer shares (markers, grader, loop
    /// spans): J-403's resolved latency + D-22's resolved tuning.
    var currentEnvironment: SessionEnvironment {
        SessionEnvironment(
            latencyOffset_ms: resolvedLatency_ms,
            tuningCents: TuningPolicy.resolvedCents(detected: detectedTuningCents,
                                                    override: tuningOverride))
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
        machine.handle(.start(configuredCountIn_beats: countIn_beats))
        phase = machine.phase
        armRun()
    }

    func pause() { applyPause(interrupted: false) }

    private func applyPause(interrupted: Bool) {
        machine.handle(.pause)
        phase = machine.phase
        frameProducer?.pause()
        stopTicker()
        pausedByInterruption = interrupted
    }

    func resume() {
        machine.handle(.resume)
        phase = machine.phase
        pausedByInterruption = false
        frameProducer?.resume()
        startTicker()
    }

    func restartPhrase() {
        machine.handle(.restartPhrase)
        phase = machine.phase
        // Rewind to the phrase's start and REDO it honestly: the frames of
        // the abandoned attempt are dropped (a redo never grades the old
        // take against the new one), and the phrase's markers reset.
        guard let now = latestFrameT_s,
              let reference = composed[selectedPart],
              let span = SessionFeedback.phraseSpan(containing: now,
                                                    reference: reference,
                                                    environment: currentEnvironment)
        else { return }
        let cutoff = span.start - 1e-9
        let environment = currentEnvironment
        liveFrames.removeAll { $0.t >= cutoff }
        for (index, note) in reference.notes.enumerated()
        where environment.transformedTime(note.start_s) >= span.start - 1e-9
              && environment.transformedTime(note.end_s) <= span.end + 1e-9 {
            markers.removeValue(forKey: index)
        }
        frameProducer?.seek(toT_s: span.start + countInDuration_s)
        latestFrameT_s = span.start
    }

    func quit() {
        machine.handle(.quit)
        phase = machine.phase
        tearDownAudio()
        // Discarded: no result, no history row. The discard is the honesty —
        // a session that never graded is never recorded as graded.
        result = nil
    }

    func retryWeakPhrases() {
        guard result != nil else { return }
        machine.handle(.retry(configuredCountIn_beats: countIn_beats))
        phase = machine.phase
        armRun() // §12.4: armRun re-reads the reference through C-14
    }

    func retryAll() { retryWeakPhrases() }

    /// The shared per-run arming: fresh buffers, the C-14 reference, the
    /// clock facts, the frame producer, the observers, the ticker.
    private func armRun() {
        errorMessage = nil
        result = nil
        markers = [:]
        liveFrames = []
        latestFrameT_s = nil
        tailFired = false
        activeSeconds = 0
        pausedByInterruption = false
        recompose()
        refreshLatency()

        countInDuration_s = Double(machine.configuredCountIn_beats)
        let environment = currentEnvironment
        referenceEnd_s = composed[selectedPart]?.notes
            .map { environment.transformedTime($0.end_s) }.max() ?? 0

        tearDownAudio()
        wireSessionObservers()
        armProducer(environment: environment)
        startTicker()
    }

    private func armProducer(environment: SessionEnvironment) {
        guard let reference = composed[selectedPart], !reference.notes.isEmpty else {
            frameProducer = nil
            return
        }
        if isDemo {
            let end = DemoSinger.sessionEnd_s(for: reference,
                                              environment: environment,
                                              countIn_s: countInDuration_s,
                                              tail_s: Self.tail_s)
            let frames = DemoSinger.frames(for: reference,
                                           environment: environment,
                                           countIn_s: countInDuration_s,
                                           sessionEnd_s: end)
            let producer = DemoSessionFrameProducer(frames: frames)
            do {
                try producer.start(into: { [weak self] frame in
                    self?.ingest(frame: frame)
                })
                frameProducer = producer
            } catch {
                frameProducer = nil
                errorMessage = "The demo stream could not start: \(error)"
            }
        } else {
            let producer = RibbonSessionFrameProducer()
            do {
                try producer.start(into: { [weak self] frame in
                    self?.ingest(frame: frame)
                })
                frameProducer = producer
            } catch {
                // Honest: the session runs frame-less — markers never land,
                // grading reports every note not-assessable (no live frames).
                frameProducer = nil
                errorMessage = "Microphone unavailable (\(error.localizedDescription)) — the session runs without live feedback."
            }
        }
    }

    /// The interruption/route hooks (J-102's controller + J-402's policy).
    private func wireSessionObservers() {
        sessionAudio.startObserving()
        sessionAudio.onInterruptionBegan = { [weak self] in
            self?.applyPause(interrupted: true)
        }
        sessionAudio.onInterruptionEnded = {
            // Stay paused — a graded session never auto-resumes into grading.
        }
        sessionAudio.onRouteChange = { [weak self] in
            // A route change stales a loopback calibration (J-403): re-read
            // the latency so the badge shows the honest state immediately.
            self?.refreshLatency()
        }
    }

    /// Releases the audio resources (producer + observers). Idempotent; does
    /// NOT touch results — called on quit, on done, and from onDisappear.
    func tearDownAudio() {
        frameProducer?.stop()
        frameProducer = nil
        stopTicker()
        sessionAudio.onInterruptionBegan = nil
        sessionAudio.onInterruptionEnded = nil
        sessionAudio.onRouteChange = nil
        sessionAudio.stopObserving()
    }

    // MARK: The audio clock's events

    /// The ticker's tick: a count-in beat during COUNT-IN, the tail check
    /// during ACTIVE (the frame clock drives the precise tail; this is the
    /// pause-aware fallback for the frame-less path).
    private func tickerFired() {
        switch phase {
        case .countIn:
            machine.handle(.countInBeatElapsed)
            phase = machine.phase
            if !phase.isLive { stopTicker() }
        case .active:
            activeSeconds += 1
            let deadline = (referenceEnd_s + Self.tail_s).rounded(.up)
            if !tailFired, Double(activeSeconds) >= deadline {
                tailFired = true
                tailElapsed()
            }
        default:
            stopTicker()
        }
    }

    /// The last note ended and the 1 s tail elapsed (the transport's event).
    func tailElapsed() {
        machine.handle(.sessionTailElapsed)
        phase = machine.phase
        if phase == .done {
            tearDownAudio()
            grade()
        }
    }

    /// A live grading-grade frame from the producer (the audio queue's call;
    /// non-blocking — hop to the main actor for the buffer + marker math).
    nonisolated func ingest(frame: PitchFrame) {
        Task { @MainActor in
            self.buffer(frame)
        }
    }

    private func buffer(_ frame: PitchFrame) {
        // Frames are captured (not graded) during COUNT-IN and ACTIVE; PAUSED
        // holds them (§5.4 — the transport is frozen, so is the stream).
        switch phase {
        case .countIn, .active: break
        default: return
        }
        // THE ONE CLOCK TRANSLATION: session-local t → reference-aligned t
        // (the reference begins at t = countIn_s).
        var aligned = frame
        aligned.t = frame.t - countInDuration_s
        liveFrames.append(aligned)
        latestFrameT_s = aligned.t

        let environment = currentEnvironment
        // The frame-clock tail (precise; the ticker is the fallback).
        if case .active = phase, !tailFired,
           aligned.t >= referenceEnd_s + Self.tail_s - 1e-9 {
            tailFired = true
            tailElapsed()
            return
        }
        // The real-time markers (§5.4): when a note's window closes, its dot
        // lands. Cheap: only the not-yet-marked notes are examined.
        let closed = SessionFeedback.closedNoteIndices(
            reference: composed[selectedPart] ?? NoteTrack(part: selectedPart, notes: []),
            environment: environment, atLiveTime_s: aligned.t)
        for index in closed where markers[index] == nil {
            let note = composed[selectedPart]?.notes.indices.contains(index) == true
                ? composed[selectedPart]!.notes[index] : nil
            guard let note else { continue }
            let inSpan = liveFrames.filter {
                let referenceT = environment.referenceTime(forLiveT: $0.t)
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
    ///
    /// THE P-401 SEAM: the grade input is the buffered live stream. When
    /// P-401's aligned SwiftF0 batch lands, ITS frames replace `liveFrames`
    /// here (the aligned-batch producer conforms to SessionFrameProducing;
    /// this method's shape does not change).
    private func grade() {
        let reference = composed[selectedPart]
        let environment = currentEnvironment
        let config = effectiveConfig
        let referenceInfo = gradingReference
        let frames = liveFrames
        let part = selectedPart
        let sessionId = UUID().uuidString
        let createdAt = ISO8601Timestamp.now()
        let id = bundleId
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try environment.validatedForGrading()
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

    // MARK: The weak-phrase retry queue (§12.4)

    /// The weak phrases of the finished result (the results screen's queue).
    var weakPhrases: [PerPhraseResult] {
        guard let result else { return [] }
        return WeakPhrasePicker.phrases(in: result)
    }

    /// A weak phrase's loop region — the span the retry plays (and loops)
    /// against. THE P-402 SEAM: the transport consumes this when the audio
    /// loop lands; until then the span is exposed and tested, no fake audio.
    func loopSpan(for phrase: PerPhraseResult) -> (start: Double, end: Double)? {
        guard let result, let reference = composed[selectedPart] else { return nil }
        return WeakPhrasePicker.loopSpan(forPhraseIndex: phrase.phraseIndex,
                                         in: result,
                                         reference: reference,
                                         environment: currentEnvironment)
    }

    // MARK: The session ticker (1 Hz; COUNT-IN beats + the tail fallback)

    private func startTicker() {
        stopTicker()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickerFired() }
        }
        self.ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
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
