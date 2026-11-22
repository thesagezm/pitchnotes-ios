import Foundation
import SwiftUI
import EngineCore
import PitchLogic

// RibbonModel (J-101) — the ribbon's state machine (Docs/UX.md §3).
//
// Threading (UX §3.1, AGENTS §8): frames are produced off the main actor by
// the RibbonFrameSource and ingested here on the main actor; each tick REPLACES
// the current reading (never queues stale frames — < 100 ms rule). All
// decisions go through RibbonMapper (pure, unit-tested in logic-tests); this
// class only resolves the reference note, maintains the trace/window, and
// publishes small render state.
//
// J-105 swap EXECUTED: both sources live behind RibbonFrameSource —
// demo (MockEngine scripted singer, the M1 device-demo input) and liveMic
// (LivePitchFacade.ribbonFrame — REAL causal ribbon, RIBBON_MPM_YIN / 0 ms).
// The live path runs on real capture chunks once MicCapture joins the target
// (Leto's X-011a re-wiring; the adapter activates with ZERO code changes) and
// on hop-aligned silence until then — real DSP cost, honest unvoiced frames.
// Standalone-tuner semantics in liveMic mode (no reference track; §3.9).
// Settings persistence (tolerance/octave/part) lands with J-405 (M4).

@MainActor
final class RibbonModel: ObservableObject {

    // MARK: - Published render state

    /// Latest decided reading (§3.4 state table — the view's cursor + readout).
    @Published private(set) var reading: RibbonReading?
    /// Last 2 s of sung pitch (§3.3 trailing trace; unvoiced = break).
    @Published private(set) var trace: [TracePoint] = []
    /// Reference bars in the visible window (3 s history, 7 s look-ahead §3.2).
    @Published private(set) var referenceBars: [ReferenceBar] = []
    /// Song-timeline time of the newest frame (scroll anchor).
    @Published private(set) var windowTime: Double = 0
    /// Follow-window center in absolute cents (§3.3). Animates ≤ 250 ms; never
    /// jumps mid-note. Held (dimmed) through gaps.
    @Published private(set) var centerCents: Double = PartRangeChips.bass.centerCents
    @Published private(set) var centerIsHeld = false
    /// VoiceOver summary, throttled to ≤ 1 Hz (UX §7).
    @Published private(set) var spoken = "unvoiced"

    // MARK: - Configuration (UX §3.4/§3.5/§3.6; persisted from J-405/M4)

    @Published var tolerance: RibbonTolerance = .wide {
        didSet { redecideLastFrame() }
    }
    /// Octave-equivalence toggle (§3.5) — default ON.
    @Published var octaveEquivalence = true {
        didSet { redecideLastFrame() }
    }
    /// Part selection (§3.6 chips): re-centers the follow window on the part's
    /// C-6.1 preset and switches the reference NoteTrack.
    @Published var selectedPart: Part = .bass {
        didSet { if oldValue != selectedPart { rebuildSource() } }
    }
    /// Mock-singer scenario for the M1 demo (exercises every §3.4 state).
    @Published var demoScenario: MockScenario = .perfect {
        didSet { if oldValue != demoScenario { rebuildSource() } }
    }
    /// Frame source (J-105): `.demo` = scripted MockEngine singer (default —
    /// the device demo runs before mic capture wires in, X-011a);
    /// `.liveMic` = the REAL LivePitchEngine causal ribbon via
    /// `ribbonFrame(_:)` (C-6.0; standalone-tuner semantics, no reference
    /// track). Selection control = segmented Picker (J-FIX-104 — the M1 menu
    /// dropped taps when its content mutated on selection); the wiring type
    /// lives in PitchLogic (`RibbonSourceMode`) for the regression tests.
    @Published var sourceMode: RibbonSourceMode = .demo {
        didSet { if oldValue != sourceMode { rebuildSource() } }
    }
    /// D-22/J-205: the song's resolved tuning-reference offset (+ = sharp).
    /// 0 in demo/liveMic standalone modes (no song context — J-203 sets this
    /// from the playing bundle's manifest/override). The REFERENCE offsets,
    /// never the audio; the chip renders via TuningDisplay when non-zero.
    @Published var tuningOffset: Int = 0 {
        didSet { if oldValue != tuningOffset { redecideLastFrame() } }
    }

    /// Reduce Motion (§7): snap the follow window instead of animating.
    var reduceMotion = false

    struct TracePoint: Identifiable, Equatable {
        let id: Int
        let t: Double
        /// Absolute cents of the sung pitch (midi·100 + centsRef); nil = unvoiced.
        let cents: Double?
        let state: RibbonState
        let lowConfidence: Bool
    }

    struct ReferenceBar: Identifiable, Equatable {
        let id: Int
        let start_s: Double
        let end_s: Double
        /// midi·100 + cents_ref (§3.3 — bar y includes the reference's own detune).
        let absoluteCents: Double
        /// < 0.6 → 70% opacity + dashed border (§3.7 honesty).
        let confidence: Double
    }

    /// Trace length (§3.3: trailing 2 s).
    static let traceSeconds: Double = 2.0

    // MARK: - Internals

    private var consumeTask: Task<Void, Never>?
    private var noteTrack = NoteTrack(part: .bass, notes: [])
    private var lastFrame: PitchFrame?
    private var frameIndex = 0
    private var lastSpokenUpdate = Date.distantPast
    /// The real live engine (J-105). One instance per live session; `reset()`
    /// clears ribbon/VAD state on interruption per the facade contract.
    private var liveEngine: LivePitchFacade?

    init() {
        rebuildSource()
    }

    deinit {
        consumeTask?.cancel()
    }

    /// Resumes consumption after `stop()` (view lifecycle).
    func start() {
        if consumeTask == nil { rebuildSource() }
    }

    func stop() {
        consumeTask?.cancel()
        consumeTask = nil
    }

    // MARK: - Source lifecycle

    private func rebuildSource() {
        consumeTask?.cancel()
        // §3.6: selecting a part re-centers the follow window on its preset.
        centerCents = PartRangeChips.range(for: selectedPart)?.centerCents ?? centerCents
        centerIsHeld = false
        trace = []
        reading = nil
        lastFrame = nil
        frameIndex = 0

        let source: any RibbonFrameSource
        switch sourceMode {
        case .demo:
            let engine = MockEngine(scenario: demoScenario, seed: 0x5017, referencePart: selectedPart)
            noteTrack = (try? engine.noteTrack(for: selectedPart)) ?? NoteTrack(part: selectedPart, notes: [])
            source = MockRibbonFrameSource(engine: engine)
        case .liveMic:
            // Standalone tuner (§3.9): no reference track — empty NoteTrack
            // means nil reference decisions and no reference bars (honest
            // free-singing; D-12 honesty rule).
            noteTrack = NoteTrack(part: selectedPart, notes: [])
            let engine = LivePitchFacade(swiftf0Inference: PlaceholderSwiftF0Inference(),
                                         vadInference: nil) // VAD fusion arrives with the real Silero seam (X-008)
            engine.reset()
            liveEngine = engine
            source = LivePitchEngineRibbonSource(engine: engine, mic: MicChunkSourceFactory.make())
        }

        consumeTask = Task { [weak self] in
            for await frame in source.frames() {
                guard let self, !Task.isCancelled else { break }
                self.ingest(frame)
            }
        }
    }

    // MARK: - Frame ingestion (main actor; replaces, never queues)

    private func ingest(_ frame: PitchFrame) {
        lastFrame = frame
        windowTime = frame.t

        let reference = self.reference(at: frame.t)
        let r = RibbonMapper.reading(frame: frame, reference: reference,
                                     tolerance: tolerance.cents,
                                     octaveEquivalence: octaveEquivalence,
                                     referenceOffsetCents: tuningOffset)
        reading = r

        appendTrace(frame: frame, reading: r)
        rebuildBars(around: frame.t)
        updateCenter(reference: reference)
        updateSpoken(r)
    }

    /// Reference note for the frame's song time, as a RibbonReference.
    private func reference(at t: Double) -> RibbonReference? {
        guard let note = NoteTrackQuery.currentNote(in: noteTrack, at: t) else { return nil }
        return RibbonReference(midi: note.midi, centsRef: Double(note.cents_ref))
    }

    private func appendTrace(frame: PitchFrame, reading r: RibbonReading) {
        let sungCents: Double?
        if frame.hz > 0, let nearest = PitchMath.midiNearest(forHz: frame.hz) {
            sungCents = Double(nearest) * 100 + PitchMath.centsRef(hz: frame.hz, midi: nearest)
        } else {
            sungCents = nil // unvoiced → trace break (§3.4)
        }
        trace.append(TracePoint(id: frameIndex, t: frame.t, cents: sungCents,
                                state: r.state,
                                lowConfidence: r.lowConfidence && frame.hz > 0))
        frameIndex += 1
        let cutoff = frame.t - Self.traceSeconds
        while let first = trace.first, first.t < cutoff {
            trace.removeFirst()
        }
    }

    private func rebuildBars(around t: Double) {
        let visible = NoteTrackQuery.notes(in: noteTrack, from: t - 3, to: t + 7)
        referenceBars = visible.map { note in
            ReferenceBar(
                id: Int((note.start_s * 1000).rounded()), // V8: starts are unique
                start_s: note.start_s,
                end_s: note.end_s,
                absoluteCents: Double(note.midi) * 100 + Double(note.cents_ref),
                confidence: note.confidence)
        }
    }

    /// §3.3: center on the current reference note; hold last center through
    /// gaps (dimmed). Exponential smoothing ≈ the ≤ 250 ms re-center; snap
    /// under Reduce Motion.
    private func updateCenter(reference: RibbonReference?) {
        if let ref = reference {
            centerIsHeld = false
            if reduceMotion {
                centerCents = ref.absoluteCents
            } else {
                centerCents += (ref.absoluteCents - centerCents) * 0.5 // ~250 ms at 62.5 Hz
            }
        } else {
            centerIsHeld = true
        }
    }

    /// §7: ≤ 1 Hz spoken-state cadence (VoiceOver reads on label change).
    private func updateSpoken(_ r: RibbonReading) {
        let now = Date()
        guard now.timeIntervalSince(lastSpokenUpdate) >= 1.0 else { return }
        spoken = r.spokenSummary
        lastSpokenUpdate = now
    }

    /// Tolerance/octave toggles re-decide the current frame without appending
    /// a new trace point (the trace records what was sung, not settings).
    private func redecideLastFrame() {
        guard let frame = lastFrame else { return }
        reading = RibbonMapper.reading(frame: frame,
                                       reference: reference(at: frame.t),
                                       tolerance: tolerance.cents,
                                       octaveEquivalence: octaveEquivalence,
                                       referenceOffsetCents: tuningOffset)
    }
}
