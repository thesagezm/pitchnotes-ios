import XCTest
import EngineCore
@testable import PitchLogic

// J-401 · aggregation, the standing property (closer pitch ⇒ higher score),
// determinism, the golden-note bonus, phrase derivation, the A–F bands, and
// the guard rails (empty reference, out-of-range environment, the clamped
// config recorded by value).
final class SessionResultAggregationTests: XCTestCase {

    // MARK: The standing invariant (C-18): closer pitch ⇒ higher score

    func testCloserPitchAlwaysScoresHigher() throws {
        let reference = SessionFixtures.track(.bass, [SessionFixtures.note(0.5, 1.5, 60)])
        var previousOverall = 1.1
        var previousPitch = 1.1
        // The sweep stays inside the fold window (−600, +600): beyond it the
        // C-19 octave fold wraps the deviation, which is the fold WORKING,
        // not the invariant failing (the fold's own behavior is pinned in
        // SessionGraderSteadyTests).
        for cents in [0.0, 5, 10, 20, 30, 40, 49, 60, 80, 100, 300, 600] {
            let live = SessionFixtures.stream(notes: [(0.5, 1.5, 6000 + cents)])
            let result = try SessionFixtures.grade(reference: reference, live: live)
            let overall = try XCTUnwrap(result.accuracy?.overall)
            let pitch = SessionGrader.pitchScore(centerCents: cents, toleranceCents: 50)
            // Non-increasing overall as the pitch moves away…
            XCTAssertLessThanOrEqual(overall, previousOverall + 1e-12)
            // …and STRICTLY decreasing while inside the tolerance.
            if abs(cents) < 50 {
                XCTAssertLessThan(overall, previousOverall)
                XCTAssertLessThan(pitch, previousPitch)
            }
            previousOverall = overall
            previousPitch = pitch
        }
        // And the model is symmetric (mean-centered): +d and −d grade alike.
        let up = try SessionFixtures.grade(reference: reference,
                                           live: SessionFixtures.stream(notes: [(0.5, 1.5, 6030)]))
        let down = try SessionFixtures.grade(reference: reference,
                                             live: SessionFixtures.stream(notes: [(0.5, 1.5, 5970)]))
        XCTAssertEqual(up.accuracy?.overall ?? 0, down.accuracy?.overall ?? 0, accuracy: 1e-9)
    }

    // MARK: Determinism (C-18: same inputs ⇒ byte-identical result)

    func testGradingIsDeterministic() throws {
        let fixture = try SessionFixtures.load("low_confidence_unison")
        let first = try SessionFixtures.grade(reference: fixture.reference,
                                              live: fixture.live,
                                              environment: fixture.environment)
        let second = try SessionFixtures.grade(reference: fixture.reference,
                                               live: fixture.live,
                                               environment: fixture.environment)
        XCTAssertEqual(first, second)

        // Frame ORDER is not an input: the grader sorts the stream.
        var scrambled = fixture.live
        scrambled.shuffle()
        let reordered = try SessionFixtures.grade(reference: fixture.reference,
                                                  live: scrambled,
                                                  environment: fixture.environment)
        XCTAssertEqual(first, reordered)
    }

    // MARK: The golden-note bonus (C-19, [1.0, 1.5])

    func testGoldenNoteBonusRaisesTheSessionScore() throws {
        var fixture = try SessionFixtures.load("detuned_sharp_35")
        fixture.environment = SessionEnvironment(tuningCents: 0) // an imperfect session
        let baseline = try SessionFixtures.grade(fixture)
        let golden = try SessionFixtures.grade(fixture, golden: [0])
        let baselineOverall = try XCTUnwrap(baseline.accuracy?.overall)
        let goldenOverall = try XCTUnwrap(golden.accuracy?.overall)
        XCTAssertGreaterThan(goldenOverall, baselineOverall)
        XCTAssertLessThanOrEqual(goldenOverall, 1.0)
    }

    // MARK: Phrase aggregation

    func testDerivedPhrasesSplitAtLargeGaps() throws {
        // A 1.5 s gap (≥ the 1.0 s derived-phrase gap) → two phrases; the
        // 100 ms gap of steady_sung stays ONE phrase.
        let spread = SessionFixtures.track(.bass, [
            SessionFixtures.note(0.5, 1.5, 48),
            SessionFixtures.note(3.0, 4.0, 50),
        ])
        let live = SessionFixtures.stream(notes: [(0.5, 1.5, 4800), (3.0, 4.0, 5000)])
        let result = try SessionFixtures.grade(reference: spread, live: live)
        XCTAssertEqual(result.perPhrase?.map(\.phraseIndex), [0, 1])
        for phrase in try XCTUnwrap(result.perPhrase) {
            XCTAssertEqual(phrase.score, 1.0, accuracy: 0.005)
        }

        let steady = try SessionFixtures.grade(try SessionFixtures.load("steady_sung"))
        XCTAssertEqual(steady.perPhrase?.count, 1)
    }

    func testPartPresenceSpansAreThePhrasesWhenPresent() throws {
        // D-41 §2: with spans, the spans ARE the phrases (bar-aligned when a
        // score is present).
        var reference = SessionFixtures.track(.bass, [
            SessionFixtures.note(0.5, 1.5, 48),
            SessionFixtures.note(3.0, 4.0, 50),
        ])
        reference.partPresence = [
            PartPresence(phraseIndex: 0, start_s: 0.0, end_s: 2.0,
                         present: true, meanConfidence: 0.9, noteCount: 1),
            PartPresence(phraseIndex: 1, start_s: 2.0, end_s: 4.0,
                         present: true, meanConfidence: 0.9, noteCount: 1),
        ]
        let live = SessionFixtures.stream(notes: [(0.5, 1.5, 4800), (3.0, 4.0, 5000)])
        let result = try SessionFixtures.grade(reference: reference, live: live)
        XCTAssertEqual(result.perPhrase?.map(\.phraseIndex), [0, 1])
    }

    func testAPhraseWithNoGradedNotesIsOmitted() {
        // A phrase whose every member is not-assessable is OMITTED from
        // perPhrase — the notAssessable summary carries the visibility; a
        // zero there would look like a terrible phrase instead of an
        // unassessable one (D-54 §1).
        var reference = SessionFixtures.track(.bass, [
            SessionFixtures.note(0.5, 1.5, 48, confidence: 0.3), // UNASSIGNED
            SessionFixtures.note(3.0, 4.0, 50),
        ])
        reference.partPresence = [
            PartPresence(phraseIndex: 0, start_s: 0.0, end_s: 2.0,
                         present: false, meanConfidence: 0.3, noteCount: 1),
            PartPresence(phraseIndex: 1, start_s: 2.0, end_s: 4.0,
                         present: true, meanConfidence: 0.9, noteCount: 1),
        ]
        let live = SessionFixtures.stream(notes: [(0.5, 1.5, 4800), (3.0, 4.0, 5000)])
        let result = try? SessionFixtures.grade(reference: reference, live: live)
        XCTAssertEqual(result?.perPhrase?.map(\.phraseIndex), [1])
    }

    // MARK: The A–F bands (the grader's pinned thresholds)

    func testGradeBandThresholds() {
        XCTAssertEqual(GradeBand.band(forScore: 1.0), .a)
        XCTAssertEqual(GradeBand.band(forScore: 0.90), .a)
        XCTAssertEqual(GradeBand.band(forScore: 0.899), .b)
        XCTAssertEqual(GradeBand.band(forScore: 0.75), .b)
        XCTAssertEqual(GradeBand.band(forScore: 0.749), .c)
        XCTAssertEqual(GradeBand.band(forScore: 0.60), .c)
        XCTAssertEqual(GradeBand.band(forScore: 0.599), .d)
        XCTAssertEqual(GradeBand.band(forScore: 0.40), .d)
        XCTAssertEqual(GradeBand.band(forScore: 0.399), .f)
        XCTAssertEqual(GradeBand.band(forScore: 0.0), .f)
        XCTAssertEqual(SessionGrader.grade(forScore: 0.95), .a) // the grader's own path
        XCTAssertEqual(GradeBand.f.rawValue, "F")               // no "E" — C-18
    }

    // MARK: The guard rails

    func testAnEmptyReferenceIsRefused() {
        let empty = SessionFixtures.track(.bass, [])
        XCTAssertThrowsError(try SessionFixtures.grade(reference: empty, live: [])) { error in
            XCTAssertEqual(error as? SessionGrader.GraderError, .emptyReference)
        }
    }

    func testAnOutOfRangeEnvironmentIsRefusedNotClamped() {
        let reference = SessionFixtures.track(.bass, [SessionFixtures.note(0.5, 1.5, 48)])
        XCTAssertThrowsError(try SessionFixtures.grade(
            reference: reference, live: [],
            environment: SessionEnvironment(transpositionSemitones: 13))) { error in
            // C-20 §5: refused by the grader (SessionEnvironment's own
            // validation), never clamped into silent wrongness.
            XCTAssertEqual(error as? SessionEnvironment.EnvironmentError,
                           .transpositionOutOfRange(13))
        }
    }

    func testTheSessionRecordsTheClampedConfigByValue() throws {
        // C-18: `config` is embedded BY VALUE — the session records what
        // ACTUALLY graded it (the clamped values, never the wild request).
        var config = GradingConfig.default
        config.toleranceCents = 500
        let result = try SessionFixtures.grade(
            reference: SessionFixtures.track(.bass, [SessionFixtures.note(0.5, 1.5, 48)]),
            live: SessionFixtures.stream(notes: [(0.5, 1.5, 4800)]),
            config: config)
        XCTAssertEqual(result.config?.toleranceCents, 50)
        XCTAssertEqual(result.config?.weights, GradingConfig.default.weights)
    }

    // MARK: C-18's JSON shape

    func testSessionResultEncodesTheContractV12Keys() throws {
        let result = try SessionFixtures.grade(try SessionFixtures.load("low_confidence_unison"))
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as! [String: Any]

        XCTAssertEqual(object["contractVersion"] as? String, "v1.2")
        XCTAssertEqual(object["part"] as? String, "BASS")
        XCTAssertNotNil(object["sessionId"])
        XCTAssertNotNil(object["bundleId"])
        XCTAssertNotNil(object["createdAt"])
        XCTAssertEqual(object["tuningCents"] as? Int, 0)          // the C-20 environment recorded
        XCTAssertEqual(object["latencyOffset_ms"] as? Int, 0)
        XCTAssertEqual(object["transpositionSemitones"] as? Int, 0)
        XCTAssertEqual(object["tempoScale"] as? Double, 1.0)
        XCTAssertNotNil(object["gradingReference"])               // {source: "heuristic"}
        XCTAssertEqual((object["gradingReference"] as? [String: Any])?["source"] as? String, "heuristic")
        XCTAssertNotNil(object["config"])                         // embedded by value
        XCTAssertEqual((object["config"] as? [String: Any])?["toleranceCents"] as? Int, 50)

        let perNote = try XCTUnwrap(object["perNote"] as? [[String: Any]])
        let graded = perNote[0]
        XCTAssertEqual(Set(graded.keys).isSuperset(of: ["noteIndex", "hit", "centsDeviation",
                                                        "coverage", "sustain_ms", "confidenceBand",
                                                        "unison", "transitional", "notAssessable"]),
                       true)
        let excluded = perNote[2] // the UNASSIGNED note: visible exclusion, no score fields
        XCTAssertEqual(excluded["notAssessableReason"] as? String, "unassigned")
        XCTAssertNil(excluded["centsDeviation"])

        let summary = try XCTUnwrap(object["notAssessable"] as? [String: Any])
        let byReason = try XCTUnwrap(summary["byReason"] as? [String: Any])
        XCTAssertNotNil(byReason["unassigned"])
        XCTAssertNotNil(byReason["noLiveFrames"])

        let accuracy = try XCTUnwrap(object["accuracy"] as? [String: Any])
        XCTAssertTrue(Set(accuracy.keys).isSuperset(of: ["overall", "steady", "transition"]))

        XCTAssertEqual(object["grade"] as? String, "A")
        XCTAssertEqual(object["engineVersion"] as? String, SessionGrader.engineVersion)
    }

    func testSessionResultRoundTrips() throws {
        let original = try SessionFixtures.grade(try SessionFixtures.load("low_confidence_unison"))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionResult.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testOmittedOptionalsStayAbsentInJSON() throws {
        let minimal = SessionResult(sessionId: "s", bundleId: "b", part: .bass,
                                    createdAt: "2026-11-27T12:00:00Z")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(minimal)) as! [String: Any]
        XCTAssertNil(object["grade"])          // C-18's absence rule
        XCTAssertNil(object["perNote"])
        XCTAssertNil(object["accuracy"])
        XCTAssertNil(object["config"])
        XCTAssertEqual(object["contractVersion"] as? String, "v1.2")
        // And decoding the minimal file works — the four REQUIRED fields are
        // the only ones a decoder may insist on.
        let decoded = try JSONDecoder().decode(SessionResult.self,
                                               from: JSONEncoder().encode(minimal))
        XCTAssertEqual(decoded, minimal)
    }

    func testRequiredFieldsAreRequired() throws {
        let missing = #"{"sessionId": "s", "bundleId": "b", "part": "BASS"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(SessionResult.self,
                                                      from: missing.data(using: .utf8)!))
    }

    func testGradingReferenceSourceVocabulary() {
        XCTAssertEqual(GradingReferenceInfo(.overlay).source.rawValue, "correctionOverlay")
        XCTAssertEqual(GradingReferenceInfo(.scoreInformed).source.rawValue, "scoreInformed")
        XCTAssertEqual(GradingReferenceInfo(.heuristic).source.rawValue, "heuristic")
    }
}
