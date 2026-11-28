import Foundation
import EngineCore

// J-402 · The learner session's PURE state machine (UX §5.4) — no UI, no
// audio, no clock: the device layer drives the transitions with events and
// renders the phase. Everything the session flow must DECIDE (when grading
// is live, when a note's window has closed for its hit marker, which phrases
// are weak enough to retry) is a pure function here, so the SwiftUI layer
// only renders.
//
// THE STATE MACHINE (UX §5.4, verbatim):
//   READY → COUNT-IN (metronome + ring; mic captured but NOT graded — frames
//   buffer, scoring starts at beat 0) → ACTIVE (ribbon + hit markers) →
//   DONE (auto after the last note + 1 s tail) → Results.
//   Interruptions (call / backgrounding) → PAUSED from either COUNT-IN or
//   ACTIVE ("graded frames held — latency unchanged"); resume returns to
//   where it paused; restart-phrase and quit are user actions from PAUSED —
//   quit DISCARDS (no result is recorded; honesty about what never happened).

/// The session's phase. `countIn` carries the beats REMAINING (the ring
/// counts down); `paused` carries where a resume returns to.
public indirect enum SessionPhase: Equatable, Sendable {
    case ready
    case countIn(beatsRemaining: Int)
    case active
    case paused(resumesTo: SessionPhase)
    case done
    /// Quit from PAUSED: the session is discarded — no grading, no history
    /// row. A session that never graded must never look like a session that
    /// was graded (the D-54 posture, applied to flow).
    case discarded

    /// TRUE exactly when live frames should be GRADED (the §5.4 rule: the
    /// count-in buffers frames but does not score them; scoring starts at
    /// beat 0 — i.e. ACTIVE).
    public var isGradingActive: Bool {
        if case .active = self { return true }
        return false
    }

    /// TRUE while the session still exists (anything but the two terminals).
    public var isLive: Bool {
        switch self {
        case .done, .discarded: return false
        default: return true
        }
    }
}

/// The events the device layer feeds the machine.
public enum SessionEvent: Equatable, Sendable {
    /// [Start] on the READY sheet with the configured count-in length.
    case start(configuredCountIn_beats: Int)
    /// The metronome fired one beat during COUNT-IN (the audio clock's event).
    case countInBeatElapsed
    /// The last note ended and the 1 s tail elapsed (ACTIVE → DONE).
    case sessionTailElapsed
    /// A call arrived / the app backgrounded / the user paused.
    case pause
    case resume
    /// [Restart phrase] — the AUDIO position is the player's business; the
    /// machine just returns to ACTIVE.
    case restartPhrase
    /// [Quit (discard)].
    case quit
    /// [Retry weak phrases] / [Retry all] from Results: a new grading run
    /// over the same composed reference (the reference is re-read through
    /// C-14 by the CALLER at retry time — UX §12.4).
    case retry(configuredCountIn_beats: Int)
}

public struct SessionStateMachine: Equatable, Sendable {

    public var phase: SessionPhase

    public init(phase: SessionPhase = .ready) {
        self.phase = phase
    }

    /// The configured count-in beats (0–8 per C-19), remembered from the last
    /// start/retry so a resume into COUNT-IN knows the ring's length.
    public private(set) var configuredCountIn_beats: Int = 0

    public mutating func handle(_ event: SessionEvent) {
        switch (phase, event) {
        // READY: only start.
        case (.ready, .start(let beats)):
            beginRun(countIn_beats: beats)
        case (.ready, .retry(let beats)):
            // A retry arriving while still READY is just a start.
            beginRun(countIn_beats: beats)

        // COUNT-IN: the beat clock ticks down to ACTIVE.
        case (.countIn(let remaining), .countInBeatElapsed):
            phase = remaining <= 1 ? .active : .countIn(beatsRemaining: remaining - 1)

        // ACTIVE: only the tail or a pause moves it.
        case (.active, .sessionTailElapsed):
            phase = .done
        case (.active, .pause):
            phase = .paused(resumesTo: .active)

        // COUNT-IN pause: resume returns to the REMAINING beats (the ring
        // freezes; §5.4's "both timelines freeze").
        case (.countIn(let remaining), .pause):
            phase = .paused(resumesTo: .countIn(beatsRemaining: remaining))

        // PAUSED: resume / restart / quit.
        case (.paused(let resumesTo), .resume):
            phase = resumesTo
        case (.paused(let resumesTo), .restartPhrase):
            phase = resumesTo.isLive ? .active : .ready
        case (.paused, .quit):
            phase = .discarded

        // DONE: a retry starts a NEW grading run (same composed reference —
        // the caller re-composes through C-14).
        case (.done, .retry(let beats)):
            beginRun(countIn_beats: beats)

        // Everything else: the event does not apply to this phase — the
        // machine IGNORES it (a stale pause event must not corrupt a DONE
        // session's result).
        default:
            break
        }
    }

    /// The shared transition for start/retry: a new grading run with the
    /// configured count-in (0 = straight to ACTIVE — no ring).
    private mutating func beginRun(countIn_beats: Int) {
        configuredCountIn_beats = max(0, countIn_beats)
        phase = configuredCountIn_beats == 0
            ? .active
            : .countIn(beatsRemaining: configuredCountIn_beats)
    }
}

// MARK: - The hit marker (real-time feedback, §5.4's ACTIVE row)

public enum SessionFeedback {

    /// The indices of reference notes whose windows have CLOSED by reference
    /// time `now` — the moment a note's dot lands on its bar (green hit /
    /// orange miss / hollow coverage-miss is the UI's colouring of the same
    /// closed set; which notes have closed is pure time math).
    ///
    /// `now` is in REFERENCE time (the session's live clock already applies
    /// the C-20 latency mapping — a frame captured at t corresponds to
    /// reference t − offset, and the markers follow the SAME map).
    public static func closedNoteIndices(reference: NoteTrack,
                                         environment: SessionEnvironment,
                                         atLiveTime_s now: Double,
                                         sessionStart_s: Double = 0) -> [Int] {
        let now = environment.referenceTime(forLiveT: now)
        return reference.notes.enumerated().compactMap { index, note in
            let end = environment.transformedTime(note.end_s, sessionStart_s: sessionStart_s)
            return now >= end ? index : nil
        }
    }

    /// The REAL-TIME marker class for one closed note, from the frames
    /// collected so far (the cheap version of the grader's verdict — same
    /// gate, same tolerance, no aggregation): green when the note's center
    /// was inside the tolerance with enough coverage; orange when sung but
    /// off; hollow when the singer was silent over it.
    public static func marker(for note: Note,
                              frames: [PitchFrame],
                              environment: SessionEnvironment,
                              config: GradingConfig) -> Marker {
        let voiced = frames.filter {
            $0.hz > 0 && $0.loudness_db >= config.breathGate_db
        }
        let duration = max(note.end_s - note.start_s, 1e-9)
        let coverage = min(1, Double(voiced.count) * SessionGrader.hop_s / duration)
        guard !voiced.isEmpty else { return .silent }
        let refHz = environment.referenceHz(midi: note.midi, cents_ref: note.cents_ref)
        let devs = voiced.map {
            config.octaveEquivalence
                ? PitchMath.foldedCents(PitchMath.cents(from: refHz, to: $0.hz))
                : PitchMath.cents(from: refHz, to: $0.hz)
        }
        let center = devs.reduce(0, +) / Double(devs.count)
        if abs(center) <= Double(config.toleranceCents) && coverage >= SessionGrader.minCoverageForHit {
            return .hit(centerCents: center)
        }
        return .miss(centerCents: center)
    }

    public enum Marker: Equatable, Sendable {
        /// Green — sung, in tune, enough of it.
        case hit(centerCents: Double)
        /// Orange — sung but out of tolerance (the UI shows ±cents).
        case miss(centerCents: Double)
        /// Hollow — the window closed with nothing sung in it.
        case silent
    }
}

// MARK: - Weak phrases (the results screen's retry queue, §12.4)

public enum WeakPhrasePicker {

    /// The ≤ `limit` weakest phrases scoring STRICTLY BELOW `threshold`,
    /// worst first. A phrase absent from `perPhrase` (all its notes were not
    /// assessable) is NOT retryable — there is nothing to re-sing against
    /// until the reference itself changes (the honesty rule: the retry list
    /// never pretends an unassessable phrase was weak).
    public static func phrases(in result: SessionResult,
                               threshold: Double = 0.7,
                               limit: Int = 3) -> [PerPhraseResult] {
        let weak = (result.perPhrase ?? []).filter { $0.score < threshold }
        return Array(weak.sorted { $0.score < $1.score }.prefix(limit))
    }

    /// The time span a phrase's reference notes cover (transformed) — the
    /// loop region a retry plays. First note's start → last note's end; nil
    /// when the phrase has no notes in the reference (an omitted phrase).
    public static func loopSpan(forPhraseIndex phraseIndex: Int,
                                in result: SessionResult,
                                reference: NoteTrack,
                                environment: SessionEnvironment,
                                sessionStart_s: Double = 0) -> (start: Double, end: Double)? {
        guard let noteIndices = result.perNote else { return nil }
        // The phrase grouping the GRADER used is reconstructed from the
        // reference (the same derived rule: gaps ≥ the derived phrase gap
        // split). C-10 spans are not carried in SessionResult, so the
        // derived grouping is the retry's contract for now — with a scored
        // bundle the caller passes the bar-aligned spans instead.
        let notes = reference.notes
            .enumerated()
            .sorted { $0.element.start_s < $1.element.start_s }
        guard !notes.isEmpty else { return nil }
        var phrases: [[Int]] = []
        var current: [Int] = []
        for (index, _) in notes {
            if let last = current.last,
               notes[index].element.start_s - notes[last].element.end_s >= SessionGrader.derivedPhraseGap_s {
                phrases.append(current)
                current = []
            }
            current.append(index)
        }
        if !current.isEmpty { phrases.append(current) }
        guard phrases.indices.contains(phraseIndex) else { return nil }
        let members = phrases[phraseIndex].compactMap { idx in
            noteIndices.first(where: { $0.noteIndex == idx })
        }
        guard !members.isEmpty else { return nil }
        let spanned = members.compactMap { entry -> (Double, Double)? in
            guard reference.notes.indices.contains(entry.noteIndex) else { return nil }
            let note = reference.notes[entry.noteIndex]
            let span = environment.transformedSpan(start_s: note.start_s,
                                                   end_s: note.end_s,
                                                   sessionStart_s: sessionStart_s)
            return (span.start, span.end)
        }
        guard let start = spanned.map(\.0).min(), let end = spanned.map(\.1).max() else { return nil }
        return (start, end)
    }
}
