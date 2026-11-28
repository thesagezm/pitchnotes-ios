import XCTest
import EngineCore
@testable import PitchLogic

// J-401 · C-19 `GradingConfig` — the bounds, the absence rule, the
// clamp-and-report posture, and the weights-sum REJECTION (never normalized).
final class GradingConfigTests: XCTestCase {

    // MARK: The contract defaults (C-19 fixes them)

    func testDefaultsMatchContractC19() {
        let config = GradingConfig.default
        XCTAssertEqual(config.contractVersion, "v1.2")
        XCTAssertEqual(config.toleranceCents, 50)
        XCTAssertTrue(config.octaveEquivalence)
        XCTAssertEqual(config.onsetGrace_ms, 100)
        XCTAssertEqual(config.vibratoExtentCents, 50)
        XCTAssertEqual(config.breathGate_db, -60.0)
        XCTAssertEqual(config.weights, GradingWeights(pitch: 0.5, timing: 0.3, sustain: 0.2))
        XCTAssertEqual(config.weights.sum, 1.0, accuracy: 1e-12)
        XCTAssertEqual(config.goldenNoteBonus, 1.1)
        XCTAssertEqual(config.guideLevel, .ribbonPlusNotes)
        XCTAssertEqual(config.countIn_beats, 4)
        XCTAssertFalse(config.metronome)
    }

    // MARK: The absence rule (a v1.2 config file may carry a subset)

    func testSubsetDecodeCarriesDefaultsForAbsentFields() throws {
        let json = #"{"toleranceCents": 25}"#.data(using: .utf8)!
        let config = try JSONDecoder().decode(GradingConfig.self, from: json)
        XCTAssertEqual(config.toleranceCents, 25)               // the one carried key
        XCTAssertTrue(config.octaveEquivalence)                 // absent ⇒ default
        XCTAssertEqual(config.onsetGrace_ms, 100)
        XCTAssertEqual(config.vibratoExtentCents, 50)
        XCTAssertEqual(config.breathGate_db, -60.0)
        XCTAssertEqual(config.weights, GradingWeights())        // absent ⇒ default weights
        XCTAssertEqual(config.goldenNoteBonus, 1.1)
        XCTAssertEqual(config.guideLevel, .ribbonPlusNotes)
        XCTAssertEqual(config.countIn_beats, 4)
        XCTAssertFalse(config.metronome)
    }

    func testFullConfigJSONDecodes() throws {
        let json = """
        {"contractVersion": "v1.2", "toleranceCents": 10, "octaveEquivalence": false,
         "onsetGrace_ms": 80, "vibratoExtentCents": 100, "breathGate_db": -45.0,
         "weights": {"pitch": 0.6, "timing": 0.2, "sustain": 0.2},
         "goldenNoteBonus": 1.5, "guideLevel": "notes", "countIn_beats": 0,
         "metronome": true}
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(GradingConfig.self, from: json)
        XCTAssertEqual(config.toleranceCents, 10)
        XCTAssertFalse(config.octaveEquivalence)
        XCTAssertEqual(config.onsetGrace_ms, 80)
        XCTAssertEqual(config.vibratoExtentCents, 100)
        XCTAssertEqual(config.breathGate_db, -45.0)
        XCTAssertEqual(config.weights.pitch, 0.6)
        XCTAssertEqual(config.goldenNoteBonus, 1.5)
        XCTAssertEqual(config.guideLevel, .notes)
        XCTAssertEqual(config.countIn_beats, 0)
        XCTAssertTrue(config.metronome)
    }

    func testRoundTripPreservesTheConfig() throws {
        let original = GradingConfig(toleranceCents: 25, onsetGrace_ms: 120,
                                     breathGate_db: -45.0,
                                     weights: GradingWeights(pitch: 0.4, timing: 0.4, sustain: 0.2),
                                     guideLevel: .ribbon)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GradingConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: Clamp-and-report (C-19: toleranceCents explicitly; the same
    // posture for every bounded tunable)

    func testToleranceAboveRangeIsClampedAndReported() throws {
        let (clamped, report) = try GradingConfig(toleranceCents: 200).clampedForGrading()
        XCTAssertEqual(clamped.toleranceCents, 50)              // the loosest preset, no wider
        XCTAssertEqual(report.clampedFields, ["toleranceCents"])
        XCTAssertTrue(report.notes.first?.contains("toleranceCents") ?? false)
    }

    func testToleranceBelowRangeIsClampedToTheTightestPreset() throws {
        let (clamped, _) = try GradingConfig(toleranceCents: 5).clampedForGrading()
        XCTAssertEqual(clamped.toleranceCents, 10)
    }

    func testEveryBoundedTunableIsClamped() throws {
        let wild = GradingConfig(toleranceCents: 500, onsetGrace_ms: 0,
                                 vibratoExtentCents: 1000, breathGate_db: -10.0,
                                 goldenNoteBonus: 5.0, countIn_beats: 99)
        let (clamped, report) = try wild.clampedForGrading()
        XCTAssertEqual(clamped.toleranceCents, 50)
        XCTAssertEqual(clamped.onsetGrace_ms, 80)
        XCTAssertEqual(clamped.vibratoExtentCents, 100)
        XCTAssertEqual(clamped.breathGate_db, -30.0)
        XCTAssertEqual(clamped.goldenNoteBonus, 1.5)
        XCTAssertEqual(clamped.countIn_beats, 8)
        XCTAssertEqual(report.clampedFields.count, 6)
        XCTAssertEqual(report.clampedFields.count, report.notes.count) // every clamp is reported
    }

    func testInBoundsConfigIsUntouchedAndUnreported() throws {
        let (clamped, report) = try GradingConfig.default.clampedForGrading()
        XCTAssertEqual(clamped, GradingConfig.default)
        XCTAssertEqual(report, GradingConfigClampReport())
    }

    // MARK: The weights-sum rule (checked, never normalized)

    func testWeightsThatDoNotSumAreRejectedNotNormalized() {
        let broken = GradingConfig(weights: GradingWeights(pitch: 0.5, timing: 0.3, sustain: 0.1))
        XCTAssertThrowsError(try broken.clampedForGrading()) { error in
            XCTAssertEqual(error as? GradingConfigError, .weightsDoNotSum(sum: 0.9))
        }
    }

    func testWeightsWithinSumToleranceAreAccepted() throws {
        let near = GradingConfig(weights: GradingWeights(pitch: 0.4995, timing: 0.3, sustain: 0.2))
        let (clamped, report) = try near.clampedForGrading()
        XCTAssertEqual(clamped.weights.sum, 0.9995, accuracy: 1e-12) // 1.0 ± 0.001
        XCTAssertEqual(report, GradingConfigClampReport())
    }

    // MARK: The guide-level vocabulary (C-19's four exact strings)

    func testGuideLevelVocabularyIsTheFourContractStrings() throws {
        for (raw, level) in [("ribbon+notes", GradingConfig.GuideLevel.ribbonPlusNotes),
                             ("ribbon", .ribbon), ("notes", .notes), ("none", .none)] {
            let json = #"{"guideLevel": "\#(raw)"}"#.data(using: .utf8)!
            XCTAssertEqual(try JSONDecoder().decode(GradingConfig.self, from: json).guideLevel, level)
        }
        let unknown = #"{"guideLevel": "karaoke"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(GradingConfig.self, from: unknown))
    }
}
