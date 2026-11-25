import XCTest
@testable import EngineCore

// P-305 · The cross-check artifact test.
//
// The artifact (`Tests/Spikes/Fixtures/crosscheck_swiftf0_vs_basicpitch.json`)
// is produced by `Tests/Spikes/crosscheck_dump.py` from the REAL models
// (SwiftF0 + basic-pitch). It carries the Python mirror's computed values in
// its `expected` block.
//
// THIS TEST is the cross-implementation gate: the SWIFT implementation
// (EngineCore's SwiftF0NoteSegmenter + TranscriptionCrossCheck) recomputes
// the metric from the same committed frames/notes and MUST agree with the
// Python mirror's numbers. If the two implementations ever drift apart, this
// test goes RED instead of the two sides quietly publishing different
// "agreement" numbers.
//
// The numbers themselves are ALSO pinned here, so a change in the metric's
// MEANING (not just in its inputs) is a visible, deliberate change.

final class CrossCheckArtifactTests: XCTestCase {

    private struct Artifact: Decodable {
        struct Case: Decodable {
            struct SwiftF0: Decodable {
                struct Frame: Decodable {
                    var t: Double
                    var hz: Double
                    var confidence: Double
                }
                var frames: [Frame]
            }
            struct BasicPitch: Decodable {
                struct Note: Decodable {
                    var start_s: Double
                    var end_s: Double
                    var midi: Int
                }
                var notes: [Note]
            }
            struct Expected: Decodable {
                var reference_count: Int
                var hypothesis_count: Int
                var matched_count: Int
                var unmatched_reference: Int
                var unmatched_hypothesis: Int
                var pitch_mismatches: Int
                var median_onset_delta_ms: Double?
                var median_offset_delta_ms: Double?
                var reference_recall: Double
                var hypothesis_precision: Double
                var agreement_f1: Double
                var disagreement_rate: Double
            }
            var name: String
            var fixture: String
            var swiftf0: SwiftF0
            var basicpitch: BasicPitch
            var expected: Expected
        }
        var cases: [Case]
    }

    private func loadArtifact() throws -> Artifact {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // EngineCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Engine
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Tests/Spikes/Fixtures/crosscheck_swiftf0_vs_basicpitch.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Artifact.self, from: data)
    }

    func testTheSwiftImplementationAgreesWithThePythonMirror() throws {
        let artifact = try loadArtifact()
        XCTAssertEqual(artifact.cases.count, 3)

        for testCase in artifact.cases {
            // 1. The Swift segmenter over the committed SwiftF0 frames.
            let frames = testCase.swiftf0.frames.map {
                PitchFrame(t: $0.t, hz: $0.hz, confidence: $0.confidence, loudness_db: -20)
            }
            let segmented = SwiftF0NoteSegmenter.segment(frames: frames)
            XCTAssertEqual(segmented.count, testCase.expected.reference_count,
                           "case \(testCase.name): the segmenter found a different number of notes")

            // 2. The Swift comparison over the committed basic-pitch notes.
            let hypothesis = testCase.basicpitch.notes.map {
                CrossCheckNote(start_s: $0.start_s, end_s: $0.end_s, midi: $0.midi)
            }
            let report = TranscriptionCrossCheck.compare(
                reference: segmented.map { CrossCheckNote($0) },
                hypothesis: hypothesis)

            // 3. The two implementations must agree, number for number.
            let expected = testCase.expected
            XCTAssertEqual(report.referenceCount, expected.reference_count, testCase.name)
            XCTAssertEqual(report.hypothesisCount, expected.hypothesis_count, testCase.name)
            XCTAssertEqual(report.matchedCount, expected.matched_count, testCase.name)
            XCTAssertEqual(report.unmatchedReference, expected.unmatched_reference, testCase.name)
            XCTAssertEqual(report.unmatchedHypothesis, expected.unmatched_hypothesis, testCase.name)
            XCTAssertEqual(report.pitchMismatches, expected.pitch_mismatches, testCase.name)
            XCTAssertEqual(report.referenceRecall, expected.reference_recall, accuracy: 1e-9, testCase.name)
            XCTAssertEqual(report.hypothesisPrecision, expected.hypothesis_precision, accuracy: 1e-9, testCase.name)
            XCTAssertEqual(report.agreementF1, expected.agreement_f1, accuracy: 1e-9, testCase.name)
            XCTAssertEqual(report.disagreementRate, expected.disagreement_rate, accuracy: 1e-9, testCase.name)
            if let expectedOnset = expected.median_onset_delta_ms {
                XCTAssertEqual(report.medianOnsetDeltaMs ?? -1, expectedOnset, accuracy: 1e-6, testCase.name)
            }
            if let expectedOffset = expected.median_offset_delta_ms {
                XCTAssertEqual(report.medianOffsetDeltaMs ?? -1, expectedOffset, accuracy: 1e-6, testCase.name)
            }
        }
    }

    /// The MEASURED numbers, pinned.
    ///
    /// These are the numbers logged in BENCHMARKS.md (P-305). A change here is
    /// a change in what the engine MEASURES, and it must be a deliberate,
    /// documented one — not a drift.
    func testTheMeasuredNumbersArePinned() throws {
        let artifact = try loadArtifact()
        let byName = Dictionary(uniqueKeysWithValues: artifact.cases.map { ($0.name, $0.expected) })

        // (a) MONOPHONIC, five distinct notes: the two engines agree
        //     completely. This is the pipeline's baseline case.
        let mono = try XCTUnwrap(byName["bp_mono"])
        XCTAssertEqual(mono.agreement_f1, 1.0, accuracy: 1e-9)
        XCTAssertEqual(mono.disagreement_rate, 0.0, accuracy: 1e-9)
        XCTAssertEqual(mono.matched_count, 5)
        XCTAssertEqual(mono.pitch_mismatches, 0)

        // (b) MONOPHONIC with vibrato: every real note is found by both, but
        //     basic-pitch adds OCTAVE artefacts and splits one note ⇒ its
        //     precision drops. The disagreement is the TRANSCODER's artefact,
        //     and the metric says so.
        let voice = try XCTUnwrap(byName["synthetic_voice"])
        XCTAssertEqual(voice.reference_recall, 1.0, accuracy: 1e-9)
        XCTAssertEqual(voice.hypothesis_count, 9)
        XCTAssertEqual(voice.pitch_mismatches, 3)
        XCTAssertEqual(voice.agreement_f1, 5.0 / 7.0, accuracy: 1e-9)
        XCTAssertEqual(voice.disagreement_rate, 2.0 / 7.0, accuracy: 1e-9)

        // (c) POLYPHONIC (five voices): a MONOPHONIC tracker cannot see them
        //     all, so the cross-check collapses. This is the honest limit of
        //     the cross-check — it is a MONOPHONIC-vs-POLYPHONIC comparison,
        //     not a second opinion about a five-part mix.
        let satb = try XCTUnwrap(byName["satb5"])
        XCTAssertEqual(satb.reference_count, 2)
        XCTAssertEqual(satb.hypothesis_count, 7)
        XCTAssertEqual(satb.pitch_mismatches, 6)
        XCTAssertEqual(satb.agreement_f1, 2.0 / 9.0, accuracy: 1e-9)
        XCTAssertEqual(satb.disagreement_rate, 7.0 / 9.0, accuracy: 1e-9)
    }
}
