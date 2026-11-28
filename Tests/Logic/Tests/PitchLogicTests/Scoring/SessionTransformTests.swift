import XCTest
import EngineCore
@testable import PitchLogic

// J-401 · C-20 — the transposition/tempo VIEW transform, the tuningCents
// preservation, the latency sign, and the refuse-never-clamp ranges. The
// key_tempo_shift fixture pins the exact mapping the CONTRACT determines.
final class SessionTransformTests: XCTestCase {

    private func fixture() throws -> SessionFixtures.Loaded {
        try SessionFixtures.load("key_tempo_shift")
    }

    // MARK: The C-20 §1 view transform (the fixture's expectedTransformed)

    func testKeyTempoShiftFixtureTransformMatchesExpectedTransformed() throws {
        let loaded = try fixture()
        let environment = loaded.environment // transposition +2, tempoScale 1.25
        let expected = try XCTUnwrap(loaded.expectedTransformed)

        let transformed = loaded.reference.notes.map { note -> [String: Double] in
            let span = environment.transformedSpan(start_s: note.start_s, end_s: note.end_s)
            return ["midi": Double(environment.transformedMidi(note.midi)),
                    "start_s": span.start, "end_s": span.end,
                    "cents_ref": Double(note.cents_ref)]
        }

        XCTAssertEqual(transformed.count, expected.count)
        for (got, want) in zip(transformed, expected) {
            XCTAssertEqual(got["midi"], want["midi"] as? Double)
            XCTAssertEqual(got["start_s"] ?? 0, want["start_s"] as? Double ?? 0, accuracy: 1e-9)
            XCTAssertEqual(got["end_s"] ?? 0, want["end_s"] as? Double ?? 0, accuracy: 1e-9)
            XCTAssertEqual(got["cents_ref"], want["cents_ref"] as? Double) // §3: UNCHANGED
        }
    }

    // MARK: The overlay transforms identically (C-20 §2)

    func testOverlaySplitAtTransformsByTheSameTimeMap() throws {
        let loaded = try fixture()
        let environment = loaded.environment
        let overlay = try XCTUnwrap(loaded.correctionOverlay)
        let splitAt = try XCTUnwrap(overlay.operations.first { $0.kind == .split }?.splitAt_s)

        // 1.5 s at tempoScale 1.25 → 1.2 s — the SAME map the note times use.
        XCTAssertEqual(environment.transformedTime(splitAt), 1.2, accuracy: 1e-9)
        // And it equals the map that moved the note it corrects:
        let note0 = loaded.reference.notes[0]
        XCTAssertEqual(environment.transformedTime(splitAt) - environment.transformedTime(note0.start_s),
                       (splitAt - note0.start_s) / environment.tempoScale, accuracy: 1e-9)
    }

    // MARK: tuningCents is preserved under transposition (C-20 §3)

    func testTuningCentsIsPreservedUnderTransposition() {
        // A +32c recording shifted +2 semitones grades against +32c, not A440.
        let environment = SessionEnvironment(tuningCents: 32, transpositionSemitones: 2)
        XCTAssertEqual(environment.referenceCents(midi: 48, cents_ref: 0),
                       50 * 100 + 32, accuracy: 1e-9)
        XCTAssertEqual(environment.referenceHz(midi: 48, cents_ref: 0),
                       PitchMath.hz(forMidi: 50) * pow(2.0, 32.0 / 1200.0), accuracy: 1e-9)
        // The note's own cents_ref also survives (a semitone shift adds
        // exactly 100·n — nothing else moves).
        XCTAssertEqual(environment.referenceCents(midi: 48, cents_ref: 12),
                       50 * 100 + 12 + 32, accuracy: 1e-9)
    }

    // MARK: The latency sign (C-20 §4: ≥ 0 = live is LATE)

    func testLatencySignLiveLateComparesAgainstTheEarlierReference() {
        let environment = SessionEnvironment(latencyOffset_ms: 200)
        // A frame captured at 1.3 s corresponds to reference time 1.1 s.
        XCTAssertEqual(environment.referenceTime(forLiveT: 1.3), 1.1, accuracy: 1e-9)
        XCTAssertEqual(environment.referenceTime(forLiveT: 0.5), 0.3, accuracy: 1e-9)
        XCTAssertEqual(environment.latencyOffset_s, 0.2, accuracy: 1e-12)
    }

    // MARK: The ranges are refused, never clamped (C-20 §5)

    func testTranspositionOutOfRangeIsRefused() {
        let environment = SessionEnvironment(transpositionSemitones: 13)
        XCTAssertThrowsError(try environment.validatedForGrading()) { error in
            XCTAssertEqual(error as? SessionEnvironment.EnvironmentError,
                           .transpositionOutOfRange(13))
        }
        // −13 refuses too; the boundary values do not.
        XCTAssertThrowsError(try SessionEnvironment(transpositionSemitones: -13).validatedForGrading())
        XCTAssertNoThrow(try SessionEnvironment(transpositionSemitones: -12).validatedForGrading())
        XCTAssertNoThrow(try SessionEnvironment(transpositionSemitones: 12).validatedForGrading())
    }

    func testTempoScaleOutOfRangeIsRefused() {
        XCTAssertThrowsError(try SessionEnvironment(tempoScale: 0.4).validatedForGrading()) { error in
            XCTAssertEqual(error as? SessionEnvironment.EnvironmentError,
                           .tempoScaleOutOfRange(0.4))
        }
        XCTAssertThrowsError(try SessionEnvironment(tempoScale: 2.1).validatedForGrading())
        XCTAssertNoThrow(try SessionEnvironment(tempoScale: 0.5).validatedForGrading())
        XCTAssertNoThrow(try SessionEnvironment(tempoScale: 2.0).validatedForGrading())
    }

    // MARK: The transform is a VIEW — the reference track is never rewritten

    func testGradingNeverMutatesTheReferenceTrack() throws {
        let loaded = try SessionFixtures.load("steady_sung")
        let before = loaded.reference
        let environment = SessionEnvironment(tuningCents: 17, transpositionSemitones: -3,
                                             tempoScale: 0.75)
        _ = try SessionFixtures.grade(reference: loaded.reference, live: loaded.live,
                                      environment: environment)
        XCTAssertEqual(loaded.reference, before) // C-20 §1: a view, never a rewrite
    }

    // MARK: The tempo mapping composes with grading (a 1.25× session still
    // grades the sung notes against the scaled reference)

    func testTempoShiftKeepsGradingAligned() throws {
        // A reference at 1.0–2.0 s sung by a stream that follows the 1.25×
        // tempo: the note is sung at 0.8–1.6 s (the transform's own mapping).
        let reference = SessionFixtures.track(.bass, [SessionFixtures.note(1.0, 2.0, 48)])
        let live = SessionFixtures.stream(notes: [(0.8, 1.6, 4800.0)])
        let result = try SessionFixtures.grade(reference: reference, live: live,
                                               environment: SessionEnvironment(tempoScale: 1.25))
        let first = try XCTUnwrap(result.perNote?.first)
        XCTAssertEqual(first.centsDeviation ?? 99, 0, accuracy: 0.01)
        XCTAssertEqual(first.hit, true)
    }
}
