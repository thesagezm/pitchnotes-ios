import XCTest
@testable import EngineCore

// P-402 · The C-20 playback-transform tests. Every clause of CONTRACTS v1.2
// C-20 is pinned here — the transform is the ONE mapping the playback engine
// (P-402's player) and the grader (J-401/J-402, Jess's lane) must agree on;
// if one of these numbers moves, BOTH sides move deliberately or not at all.

final class PlaybackTransformTests: XCTestCase {

    // MARK: - C-20 §5: the ranges are REFUSED, never clamped

    func testTheEnvironmentRangesAreRefusedNotClamped() {
        // transpositionSemitones ∈ [−12, +12]
        XCTAssertThrowsError(try PlaybackEnvironment(transpositionSemitones: 13))
        XCTAssertThrowsError(try PlaybackEnvironment(transpositionSemitones: -13))
        // tempoScale ∈ [0.5, 2.0]
        XCTAssertThrowsError(try PlaybackEnvironment(tempoScale: 2.1))
        XCTAssertThrowsError(try PlaybackEnvironment(tempoScale: 0.49))
        // The boundaries themselves are ADMISSIBLE.
        XCTAssertNoThrow(try PlaybackEnvironment(transpositionSemitones: 12, tempoScale: 2.0))
        XCTAssertNoThrow(try PlaybackEnvironment(transpositionSemitones: -12, tempoScale: 0.5))
        // And the error names which bound was hit (the UI refuses with a
        // reason, never a silent clamp — C-20 §5).
        do {
            _ = try PlaybackEnvironment(transpositionSemitones: 25)
            XCTFail("must throw")
        } catch let error as PlaybackEnvironmentError {
            XCTAssertEqual(error, .transpositionOutOfRange(25))
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    // MARK: - C-20 §1: midi' = midi + n

    func testTranspositionMovesMidiByWholeSemitones() throws {
        let env = try PlaybackEnvironment(transpositionSemitones: 2)
        let transform = PlaybackTransform(environment: env)
        XCTAssertEqual(transform.mapMidi(45), 47)
        XCTAssertEqual(transform.mapMidi(60), 62)
        XCTAssertEqual(transform.mapMidi(96), 98, "the V9 ceiling moves too — a shifted track may re-range outside 24…96; the UI refuses what it cannot play")
        let down = PlaybackTransform(environment: try PlaybackEnvironment(transpositionSemitones: -5))
        XCTAssertEqual(down.mapMidi(45), 40)
    }

    // MARK: - C-20 §1: the time mapping scales about the session start

    func testTempoScalingFollowsTheContractFormula() throws {
        // The contract's own example: tempoScale 1.25 renders a 4.0 s phrase
        // as 3.2 s.
        let faster = PlaybackTransform(environment: try PlaybackEnvironment(tempoScale: 1.25))
        let (s, e) = faster.mapInterval(start: 0.0, end: 4.0)
        XCTAssertEqual(s, 0.0, accuracy: 1e-12)
        XCTAssertEqual(e, 3.2, accuracy: 1e-12)
        // Slower than original: 0.5× doubles the span.
        let slower = PlaybackTransform(environment: try PlaybackEnvironment(tempoScale: 0.5))
        let (s2, e2) = slower.mapInterval(start: 0.0, end: 4.0)
        XCTAssertEqual(e2, 8.0, accuracy: 1e-12)
        // A note STAYS a note (start' < end') under every admissible scale.
        for scale: Double in [0.5, 0.75, 1.0, 1.5, 2.0] {
            let t = PlaybackTransform(environment: try PlaybackEnvironment(tempoScale: scale))
            let interval = t.mapInterval(start: 2.0, end: 5.0)
            XCTAssertLessThan(interval.start, interval.end)
        }
    }

    func testTempoScalingPivotsAboutTheSessionStart() throws {
        // A session that begins at t = 30 s: the phrase AT the start does not
        // move (the pivot's own point is fixed), everything else scales away
        // from it.
        let transform = PlaybackTransform(
            environment: try PlaybackEnvironment(tempoScale: 1.25), sessionStart_s: 30)
        XCTAssertEqual(transform.mapTime(30.0), 30.0, accuracy: 1e-12,
                       "the pivot point itself is fixed")
        // 6 s after the session start ⇒ 30 + 6/1.25 = 34.8.
        XCTAssertEqual(transform.mapTime(36.0), 34.8, accuracy: 1e-12)
        // BEFORE the session start it scales the other way (the formula is
        // uniform — the contract does not special-case it): 30 + (18−30)/1.25.
        XCTAssertEqual(transform.mapTime(18.0), 20.4, accuracy: 1e-12)
    }

    func testTheNeutralEnvironmentIsTheIdentity() throws {
        let transform = PlaybackTransform(environment: .neutral)
        for t: Double in [0, 1.5, 30.25] {
            XCTAssertEqual(transform.mapTime(t), t, accuracy: 1e-12)
        }
        XCTAssertEqual(transform.mapMidi(60), 60)
    }

    // MARK: - C-20 §1 applied to engine tracks: a view that invents nothing

    func testTheTransformAppliesToATrackAndInventsNothing() throws {
        let original = EngineCore.Note(start_s: 2.0, end_s: 6.0, midi: 55,
                                       cents_ref: 0, confidence: 0.91234)
        let track = NoteTrack(contractVersion: NoteTrack.contractVersionV11,
                              part: .bass, notes: [original],
                              engineVersion: "note-track-0.3.0")
        let transform = PlaybackTransform(
            environment: try PlaybackEnvironment(transpositionSemitones: 2, tempoScale: 1.25))

        let mapped = transform.apply(to: track)
        XCTAssertEqual(mapped.notes.count, 1, "never adds, removes or reorders")
        let note = mapped.notes[0]
        XCTAssertEqual(note.midi, 57)
        // The WHOLE reference scales about the session start (0 here): the
        // note's span [2, 6) maps to [1.6, 4.8) — start and end alike.
        XCTAssertEqual(note.start_s, 2.0 / 1.25, accuracy: 1e-12)
        XCTAssertEqual(note.end_s, 6.0 / 1.25, accuracy: 1e-12)
        // Every other field is CARRIED, never rewritten (the transform is a
        // view — C-20 §1).
        XCTAssertEqual(note.confidence, 0.91234, accuracy: 1e-12)
        XCTAssertEqual(note.cents_ref, 0)
        XCTAssertEqual(mapped.part, .bass)
        XCTAssertEqual(mapped.contractVersion, track.contractVersion,
                       "the on-disk schema family string is untouched — the transform is not a rewrite")
        XCTAssertEqual(mapped.engineVersion, track.engineVersion)
        // And the ORIGINAL is untouched (a view over a copy at load).
        XCTAssertEqual(track.notes[0].midi, 55)
        XCTAssertEqual(track.notes[0].start_s, 2.0, accuracy: 1e-12)
    }

    func testTheTransformPreservesOrderSoIndexedOverlaysStayValid() throws {
        // C-20 §2: C-11's ops address notes by INDEX; the transform must
        // never add, remove or reorder. Three notes with distinct onsets map
        // in the same order.
        let notes = [
            EngineCore.Note(start_s: 1.0, end_s: 2.0, midi: 48, confidence: 0.9),
            EngineCore.Note(start_s: 3.0, end_s: 4.0, midi: 50, confidence: 0.9),
            EngineCore.Note(start_s: 5.0, end_s: 6.0, midi: 52, confidence: 0.9),
        ]
        let track = NoteTrack(contractVersion: NoteTrack.contractVersionV11,
                              part: .baritone, notes: notes)
        let transform = PlaybackTransform(
            environment: try PlaybackEnvironment(transpositionSemitones: -3, tempoScale: 0.75))
        let mapped = transform.apply(to: track)
        XCTAssertEqual(mapped.notes.map(\.midi), [45, 47, 49])
        let onsets = mapped.notes.map(\.start_s)
        XCTAssertEqual(onsets, onsets.sorted(), "order preserved")
    }

    // MARK: - C-20 §2: the overlay maps identically to the track it corrects

    func testOverlayTimesMapThroughTheSameTimeMapping() throws {
        // A split at t = 3.0 s between two notes: under any environment the
        // split maps to EXACTLY what the notes' own boundaries map to —
        // "a corrected split stays corrected under any key/tempo" (C-20 §2).
        let transform = PlaybackTransform(
            environment: try PlaybackEnvironment(transpositionSemitones: 4, tempoScale: 1.5))
        let before = transform.mapInterval(start: 1.0, end: 3.0)  // note 0's span
        let after = transform.mapInterval(start: 3.0, end: 5.0)   // note 1's span
        let splitAt = transform.mapTime(3.0)
        XCTAssertEqual(splitAt, before.end, accuracy: 1e-12,
                       "the split sits exactly at note 0's mapped end")
        XCTAssertEqual(splitAt, after.start, accuracy: 1e-12,
                       "and exactly at note 1's mapped start — same mapping, no drift")
        // An overlay is expressed in UNTRANSPOSED bundle time and mapped BY
        // the caller through this ONE function — never pre-transposed.
        XCTAssertEqual(transform.mapTime(0.0), 0.0, accuracy: 1e-12)
    }

    // MARK: - C-20 §3: tuningCents is PRESERVED under transposition

    func testTuningCentsArePreservedUnderTransposition() throws {
        // The contract's own case: a +32c recording shifted +2 grades
        // against +32c, NOT against A440 (D-22: the reference offsets, never
        // the audio).
        let transform = PlaybackTransform(
            environment: try PlaybackEnvironment(transpositionSemitones: 2))
        XCTAssertEqual(transform.referenceCents(midi: 55, tuningCents: 32.0),
                       57 * 100 + 32.0, accuracy: 1e-9)
        // A semitone shift adds EXACTLY 100·n cents — no scaling of the
        // tuning deviation.
        let down = PlaybackTransform(
            environment: try PlaybackEnvironment(transpositionSemitones: -1))
        XCTAssertEqual(down.referenceCents(midi: 60, tuningCents: -18.0),
                       59 * 100 - 18.0, accuracy: 1e-9)
        // The resolved value the session records (C-18's tuningCents) is the
        // composed value the caller passed in — this type adds nothing.
        let neutral = PlaybackTransform(environment: .neutral)
        XCTAssertEqual(neutral.referenceCents(midi: 60, tuningCents: 32.0),
                       6000 + 32.0, accuracy: 1e-9)
    }

    // MARK: - C-20 §4: the latency sign convention is PINNED

    func testTheLatencySignConventionMatchesTheContract() {
        let transform = PlaybackTransform(environment: .neutral)
        // offset ≥ 0 = the live path is LATE: the live frame at t compares
        // against the EARLIER reference at t − offset.
        XCTAssertEqual(transform.referenceTime(forLiveTime: 1.500, latencyOffset_ms: 85),
                       1.415, accuracy: 1e-12)
        // The contract's C-18 example environment (latencyOffset_ms: 0) is
        // the identity.
        XCTAssertEqual(transform.referenceTime(forLiveTime: 2.0, latencyOffset_ms: 0),
                       2.0, accuracy: 1e-12)
        // A negative value (a device whose live path reads EARLY) symmetrically
        // shifts the comparison window later.
        XCTAssertEqual(transform.referenceTime(forLiveTime: 2.0, latencyOffset_ms: -40),
                       2.040, accuracy: 1e-12)
    }

    // MARK: - The varispeed fact (RESEARCH A.2.8 — confirmed by the
    // PlaybackKit offline-render measurement on the macOS runner)

    func testTheVarispeedCompensationFormula() {
        XCTAssertEqual(VarispeedPitchCompensation.semitones(forSpeed: 1.0), 0.0, accuracy: 1e-12)
        XCTAssertEqual(VarispeedPitchCompensation.semitones(forSpeed: 2.0), -12.0, accuracy: 1e-12)
        XCTAssertEqual(VarispeedPitchCompensation.semitones(forSpeed: 0.5), 12.0, accuracy: 1e-12)
        // −12·log2(1.25) = −3.863137… (measured constant, not a hand guess).
        XCTAssertEqual(VarispeedPitchCompensation.semitones(forSpeed: 1.25), -3.863_137, accuracy: 1e-6)
        // The inverse mapping returns the speed.
        XCTAssertEqual(VarispeedPitchCompensation.speed(forSemitones: -3.863_137), 1.25, accuracy: 1e-6)
        XCTAssertEqual(VarispeedPitchCompensation.speed(forSemitones: 12.0), 0.5, accuracy: 1e-12)
        // And the round trip is the identity.
        for speed: Double in [0.5, 0.8, 1.0, 1.25, 2.0] {
            let semis = VarispeedPitchCompensation.semitones(forSpeed: speed)
            XCTAssertEqual(VarispeedPitchCompensation.speed(forSemitones: semis), speed, accuracy: 1e-9)
        }
    }

    // MARK: - The session environment records exactly what the transform used

    func testTheEnvironmentIsTheRecordedSessionEnvironment() throws {
        // C-18 records {transpositionSemitones, tempoScale} — the values the
        // grader replayed against. The environment round-trips as the same
        // values, byte-identical determinism (J-401's AC).
        let env = try PlaybackEnvironment(transpositionSemitones: -2, tempoScale: 0.9)
        let transform = PlaybackTransform(environment: env, sessionStart_s: 12.5)
        XCTAssertEqual(transform.environment, env)
        XCTAssertEqual(transform.environment.tempoScale, 0.9, accuracy: 1e-12)
        XCTAssertEqual(transform.sessionStart_s, 12.5, accuracy: 1e-12)
    }
}
