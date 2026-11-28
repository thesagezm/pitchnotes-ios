import XCTest
import EngineCore
@testable import PitchLogic

// J-402 · The learner session's pure state machine (UX §5.4), the grading
// gate (the count-in buffers but never scores), the real-time hit markers,
// and the weak-phrase retry queue.
final class SessionFlowTests: XCTestCase {

    // MARK: The state machine (§5.4)

    func testTheHappyPathReadyThroughCountInToActiveToDone() {
        var machine = SessionStateMachine()
        XCTAssertEqual(machine.phase, .ready)
        machine.handle(.start(configuredCountIn_beats: 2))
        XCTAssertEqual(machine.phase, .countIn(beatsRemaining: 2))
        machine.handle(.countInBeatElapsed)
        XCTAssertEqual(machine.phase, .countIn(beatsRemaining: 1))
        machine.handle(.countInBeatElapsed)
        XCTAssertEqual(machine.phase, .active) // scoring starts at beat 0
        machine.handle(.sessionTailElapsed)
        XCTAssertEqual(machine.phase, .done)
    }

    func testAZeroCountInGoesStraightToActive() {
        var machine = SessionStateMachine()
        machine.handle(.start(configuredCountIn_beats: 0))
        XCTAssertEqual(machine.phase, .active) // no ring, straight in
    }

    func testTheCountInDoesNotGrade() {
        var machine = SessionStateMachine()
        machine.handle(.start(configuredCountIn_beats: 4))
        XCTAssertFalse(machine.phase.isGradingActive) // frames buffer, never score
        machine.handle(.countInBeatElapsed)
        machine.handle(.countInBeatElapsed)
        machine.handle(.countInBeatElapsed)
        machine.handle(.countInBeatElapsed)
        XCTAssertTrue(machine.phase.isGradingActive)
        machine.handle(.sessionTailElapsed)
        XCTAssertFalse(machine.phase.isGradingActive)
    }

    func testInterruptionPausesAndResumeReturnsToWhereItWas() {
        // From ACTIVE.
        var machine = SessionStateMachine()
        machine.handle(.start(configuredCountIn_beats: 0))
        machine.handle(.pause)
        XCTAssertEqual(machine.phase, .paused(resumesTo: .active))
        machine.handle(.resume)
        XCTAssertEqual(machine.phase, .active)

        // From COUNT-IN: the remaining beats freeze and resume.
        machine.handle(.pause)
        machine.handle(.resume)
        XCTAssertEqual(machine.phase, .active)
    }

    func testAPausedCountInResumesWithItsRemainingBeats() {
        var machine = SessionStateMachine()
        machine.handle(.start(configuredCountIn_beats: 4))
        machine.handle(.countInBeatElapsed)
        machine.handle(.countInBeatElapsed) // 2 remain
        machine.handle(.pause)
        XCTAssertEqual(machine.phase, .paused(resumesTo: .countIn(beatsRemaining: 2)))
        machine.handle(.resume)
        XCTAssertEqual(machine.phase, .countIn(beatsRemaining: 2))
        machine.handle(.countInBeatElapsed)
        machine.handle(.countInBeatElapsed)
        XCTAssertEqual(machine.phase, .active)
    }

    func testRestartPhraseReturnsToActiveFromPaused() {
        var machine = SessionStateMachine()
        machine.handle(.start(configuredCountIn_beats: 0))
        machine.handle(.pause)
        machine.handle(.restartPhrase)
        XCTAssertEqual(machine.phase, .active)
    }

    func testQuitDiscardsAndNoResultStoryFollows() {
        var machine = SessionStateMachine()
        machine.handle(.start(configuredCountIn_beats: 0))
        machine.handle(.pause)
        machine.handle(.quit)
        XCTAssertEqual(machine.phase, .discarded)
        XCTAssertFalse(machine.phase.isLive)
        // Stale events cannot resurrect a discarded session.
        machine.handle(.resume)
        machine.handle(.sessionTailElapsed)
        XCTAssertEqual(machine.phase, .discarded)
    }

    func testStaleEventsCannotCorruptADoneSession() {
        var machine = SessionStateMachine()
        machine.handle(.start(configuredCountIn_beats: 0))
        machine.handle(.sessionTailElapsed)
        machine.handle(.pause)              // stale (an interruption arriving late)
        machine.handle(.countInBeatElapsed) // stale
        XCTAssertEqual(machine.phase, .done)
    }

    func testRetryStartsANewRunFromDone() {
        var machine = SessionStateMachine()
        machine.handle(.start(configuredCountIn_beats: 0))
        machine.handle(.sessionTailElapsed)
        machine.handle(.retry(configuredCountIn_beats: 2))
        XCTAssertEqual(machine.phase, .countIn(beatsRemaining: 2))
        XCTAssertFalse(machine.phase.isGradingActive) // the new run's count-in buffers too
    }

    // MARK: The real-time hit markers

    func testClosedNoteIndicesFollowTheLatencyMap() {
        let reference = SessionFixtures.track(.bass, [
            SessionFixtures.note(1.0, 2.0, 48),
            SessionFixtures.note(2.0, 3.0, 50),
        ])
        let environment = SessionEnvironment(latencyOffset_ms: 200)
        // Live clock 2.1 s = reference 1.9 s: only the FIRST note's window
        // (ends at 2.0) has not closed yet.
        XCTAssertEqual(SessionFeedback.closedNoteIndices(reference: reference,
                                                         environment: environment,
                                                         atLiveTime_s: 2.1), [])
        // Live 2.3 = reference 2.1: the first note closed.
        XCTAssertEqual(SessionFeedback.closedNoteIndices(reference: reference,
                                                         environment: environment,
                                                         atLiveTime_s: 2.3), [0])
        // Live 3.3 = reference 3.1: both closed (the second note ends at 3.0).
        XCTAssertEqual(SessionFeedback.closedNoteIndices(reference: reference,
                                                         environment: environment,
                                                         atLiveTime_s: 3.3), [0, 1])
    }

    func testMarkerClassesHitMissAndSilent() {
        let note = SessionFixtures.note(0.5, 1.5, 48)
        let onPitch = SessionFixtures.stream(notes: [(0.5, 1.5, 4800)])
        XCTAssertEqual(SessionFeedback.marker(for: note, frames: onPitch,
                                              environment: SessionEnvironment(),
                                              config: .default),
                       .hit(centerCents: 0.0))

        let flat = SessionFixtures.stream(notes: [(0.5, 1.5, 4770)]) // −30c: inside, but shown
        if case .hit = SessionFeedback.marker(for: note, frames: flat,
                                              environment: SessionEnvironment(),
                                              config: .default) {
            // −30c inside ±50 is still a hit — the marker carries the center.
        } else {
            XCTFail("−30c with coverage is a hit")
        }

        let off = SessionFixtures.stream(notes: [(0.5, 1.5, 4900)]) // +100c
        if case .miss(let center) = SessionFeedback.marker(for: note, frames: off,
                                                           environment: SessionEnvironment(),
                                                           config: .default) {
            XCTAssertEqual(center, 100.0, accuracy: 1e-6)
        } else {
            XCTFail("+100c is a miss")
        }

        let silent = SessionFixtures.stream(notes: [(0.5, 1.5, 4800)]).map {
            PitchFrame(t: $0.t, hz: 0.0, confidence: 0.02, loudness_db: -75.0,
                       engine_id: "SWIFTF0", lookahead_ms: 176)
        }
        XCTAssertEqual(SessionFeedback.marker(for: note, frames: silent,
                                              environment: SessionEnvironment(),
                                              config: .default),
                       .silent)
    }

    // MARK: The weak-phrase retry queue (§12.4: ≤ 3, worst first)

    func testWeakPhrasesPickTheThreeWorstBelowThreshold() throws {
        var result = try SessionFixtures.grade(try SessionFixtures.load("low_confidence_unison"))
        result.perPhrase = [
            PerPhraseResult(phraseIndex: 0, score: 0.92),
            PerPhraseResult(phraseIndex: 1, score: 0.41),
            PerPhraseResult(phraseIndex: 2, score: 0.66),
            PerPhraseResult(phraseIndex: 3, score: 0.55),
            PerPhraseResult(phraseIndex: 4, score: 0.95),
        ]
        let weak = WeakPhrasePicker.phrases(in: result)
        XCTAssertEqual(weak.map(\.phraseIndex), [1, 3, 2]) // worst first, ≤ 3
        XCTAssertEqual(weak.map(\.score), [0.41, 0.55, 0.66])
    }

    func testPhrasesAtOrAboveTheThresholdAreNeverRetryWeak() {
        var result = SessionResult(sessionId: "s", bundleId: "b", part: .bass, createdAt: "t")
        result.perPhrase = [PerPhraseResult(phraseIndex: 0, score: 0.70),
                            PerPhraseResult(phraseIndex: 1, score: 0.9)]
        XCTAssertTrue(WeakPhrasePicker.phrases(in: result).isEmpty) // 0.70 is NOT below 0.70
    }

    func testTheRetryLoopSpanCoversThePhraseNotes() throws {
        let reference = SessionFixtures.track(.bass, [
            SessionFixtures.note(0.5, 1.5, 48),
            SessionFixtures.note(1.6, 2.6, 50), // same phrase (100 ms gap)
            SessionFixtures.note(5.0, 6.0, 52), // a new phrase (2.4 s gap)
        ])
        var result = SessionResult(sessionId: "s", bundleId: "b", part: .bass, createdAt: "t")
        result.perNote = [
            PerNoteResult(noteIndex: 0, hit: true),
            PerNoteResult(noteIndex: 1, hit: false),
            PerNoteResult(noteIndex: 2, hit: false),
        ]
        let firstPhrase = WeakPhrasePicker.loopSpan(forPhraseIndex: 0, in: result,
                                                    reference: reference,
                                                    environment: SessionEnvironment())
        XCTAssertEqual(firstPhrase?.start ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(firstPhrase?.end ?? 0, 2.6, accuracy: 1e-9)
        let secondPhrase = WeakPhrasePicker.loopSpan(forPhraseIndex: 1, in: result,
                                                     reference: reference,
                                                     environment: SessionEnvironment())
        XCTAssertEqual(secondPhrase?.start ?? 0, 5.0, accuracy: 1e-9)
        XCTAssertEqual(secondPhrase?.end ?? 0, 6.0, accuracy: 1e-9)
        // A phrase with no graded members has no loop span (nothing to retry).
        var empty = SessionResult(sessionId: "s", bundleId: "b", part: .bass, createdAt: "t")
        empty.perNote = [PerNoteResult(noteIndex: 0, notAssessable: true,
                                       notAssessableReason: "unassigned")]
        XCTAssertNil(WeakPhrasePicker.loopSpan(forPhraseIndex: 9, in: empty,
                                               reference: reference,
                                               environment: SessionEnvironment()))
    }
}
