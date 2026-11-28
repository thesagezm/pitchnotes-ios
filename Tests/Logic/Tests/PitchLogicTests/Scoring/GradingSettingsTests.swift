import XCTest
import EngineCore
@testable import PitchLogic

// J-405 — the grading-settings store (UX §6.4) and the CONFIG-EFFECT proofs
// (the AC: "the scoring reads the config"). Two honest rails pinned here:
//   · the store never crashes on absence/corruption — the contract defaults;
//   · a non-summing weights set is REJECTED at save (C-19 — never normalized);
//   · a value that reaches the store out-of-bounds is CLAMPED-and-REPORTED at
//     the grading path (never silently used);
//   · the same synthetic input graded under two saved settings produces the
//     DIFFERENT verdicts the settings promise — the config is real.

final class GradingSettingsTests: XCTestCase {

    private var defaults: UserDefaults {
        UserDefaults(suiteName: "grading-settings-tests")!
    }

    override func tearDown() {
        GradingSettingsStore.clear(from: defaults)
        super.tearDown()
    }

    // MARK: Persistence (the AC: "all persist")

    func testPersistenceRoundTrip() throws {
        var settings = GradingSettings()
        settings.toleranceCents = 25
        settings.octaveEquivalence = false
        settings.onsetGrace_ms = 80
        settings.vibratoExtentCents = 90
        settings.breathGate_db = -45.0
        settings.weights = GradingWeights(pitch: 0.4, timing: 0.4, sustain: 0.2)
        settings.goldenNoteBonus = 1.3
        settings.guideLevel = .notes
        settings.countIn_beats = 2
        settings.metronome = true
        settings.haptics = false

        try GradingSettingsStore.save(settings, from: defaults)
        XCTAssertEqual(GradingSettingsStore.load(from: defaults), settings)
    }

    func testAbsenceGivesTheContractDefaults() {
        XCTAssertEqual(GradingSettingsStore.load(from: defaults), .default)
    }

    func testCorruptionGivesTheContractDefaultsNeverACrash() {
        defaults.set("this is not json", forKey: GradingSettingsStore.defaultsKey)
        XCTAssertEqual(GradingSettingsStore.load(from: defaults), .default)

        // Structurally-JSON but wrong-shaped (a settings object is expected).
        defaults.set("{\"toleranceCents\": \"fifty\"}", forKey: GradingSettingsStore.defaultsKey)
        XCTAssertEqual(GradingSettingsStore.load(from: defaults), .default)
    }

    func testClearResetsTheNextReadToDefaults() throws {
        var settings = GradingSettings()
        settings.toleranceCents = 10
        try GradingSettingsStore.save(settings, from: defaults)
        GradingSettingsStore.clear(from: defaults)
        XCTAssertEqual(GradingSettingsStore.load(from: defaults), .default)
    }

    func testTheWeightsSumIsRejectedAtSaveNeverNormalized() throws {
        var settings = GradingSettings()
        settings.weights = GradingWeights(pitch: 0.5, timing: 0.3, sustain: 0.1) // 0.9
        XCTAssertThrowsError(try GradingSettingsStore.save(settings, from: defaults)) { error in
            XCTAssertEqual(error as? GradingSettingsStore.SettingsError,
                           .weightsDoNotSum(sum: 0.9))
        }
        // The store stays EMPTY — a rejected config never persisted.
        XCTAssertEqual(GradingSettingsStore.load(from: defaults), .default)
    }

    func testHapticsIsAUxPreferenceNeverAGradingInput() throws {
        var settings = GradingSettings()
        settings.haptics = false
        // Haptics round-trips through the STORE…
        try GradingSettingsStore.save(settings, from: defaults)
        XCTAssertFalse(GradingSettingsStore.load(from: defaults).haptics)
        // …and is ABSENT from the GradingConfig the scoring consumes.
        XCTAssertEqual(settings.asGradingConfig, GradingConfig.default)
    }

    // MARK: The honesty rail from the STORE to the GRADER

    func testAnOutOfBoundsStoredValueIsClampedAndReportedForGrading() throws {
        // A hand-edited plist (or a schema drift) can carry out-of-bounds
        // values — save() is bypassed with a raw payload. The GRADING path
        // clamps and REPORTS; the session records the clamped config.
        let raw = """
        {"toleranceCents": 99, "onsetGrace_ms": 5, "vibratoExtentCents": 500,
         "breathGate_db": -5.0, "goldenNoteBonus": 9.9, "countIn_beats": 40,
         "weights": {"pitch": 0.5, "timing": 0.3, "sustain": 0.2}}
        """
        defaults.set(raw, forKey: GradingSettingsStore.defaultsKey)
        let loaded = GradingSettingsStore.load(from: defaults)
        let graded = try loaded.asGradingConfig.clampedForGrading()
        XCTAssertEqual(graded.config.toleranceCents, 50)
        XCTAssertEqual(graded.config.onsetGrace_ms, 80)
        XCTAssertEqual(graded.config.vibratoExtentCents, 100)
        XCTAssertEqual(graded.config.breathGate_db, -30.0)
        XCTAssertEqual(graded.config.goldenNoteBonus, 1.5)
        XCTAssertEqual(graded.config.countIn_beats, 8)
        XCTAssertTrue(graded.report.clampedFields.contains("toleranceCents"))
        XCTAssertTrue(graded.report.notes.contains { $0.contains("clamped") })
    }

    // MARK: THE CONFIG EFFECT (the AC: "the scoring reads the config")

    /// One reference note (midi 60, 0–2 s); the stream sings +25 cents sharp
/// (ABSOLUTE cents — A4 = 6900, so midi 60 = 6000, +25c = 6025).
    private let sharpStream: (reference: NoteTrack, live: [PitchFrame]) = {
        let reference = SessionFixtures.track(.bass, [SessionFixtures.note(0, 2, 60)])
        let live = SessionFixtures.stream(notes: [(0, 2, 6025)])
        return (reference, live)
    }()

    func testToleranceSettingChangesTheVerdictOfTheSameInput() throws {
        var loose = GradingSettings()
        loose.toleranceCents = 50
        var strict = GradingSettings()
        strict.toleranceCents = 10

        let looseResult = try SessionFixtures.grade(
            reference: sharpStream.reference, live: sharpStream.live,
            config: loose.asGradingConfig)
        let strictResult = try SessionFixtures.grade(
            reference: sharpStream.reference, live: sharpStream.live,
            config: strict.asGradingConfig)

        // +25c is a HIT at ±50 and a MISS at ±10 — the setting did this.
        XCTAssertEqual(looseResult.perNote?.first?.hit, true)
        XCTAssertEqual(strictResult.perNote?.first?.hit, false)
        XCTAssertGreaterThan(looseResult.perPhrase?.first?.score ?? 0,
                             strictResult.perPhrase?.first?.score ?? 1)
    }

    func testOctaveEquivalenceSettingChangesTheVerdictOfTheSameInput() throws {
        let reference = SessionFixtures.track(.bass, [SessionFixtures.note(0, 2, 60)])
        // An exact octave ABOVE — absolute 7200 (midi 72) against midi 60.
        let live = SessionFixtures.stream(notes: [(0, 2, 7200)])
        var folding = GradingSettings()
        folding.octaveEquivalence = true
        var literal = GradingSettings()
        literal.octaveEquivalence = false

        let folded = try SessionFixtures.grade(reference: reference, live: live,
                                               config: folding.asGradingConfig)
        let unforgiven = try SessionFixtures.grade(reference: reference, live: live,
                                                   config: literal.asGradingConfig)
        XCTAssertEqual(folded.perNote?.first?.hit, true)
        XCTAssertEqual(unforgiven.perNote?.first?.hit, false)
    }

    func testVibratoExtentSettingChangesTheVerdictOfTheSameInput() throws {
        // A ±40c mean-centered wobble around midi 60 (the mean IS the note).
        let reference = SessionFixtures.track(.bass, [SessionFixtures.note(0, 2, 60)])
        var frames: [PitchFrame] = []
        var t = 0.0
        let swing: [Double] = [6000, 6040, 6000, 5960]
        var i = 0
        while t < 2.0 - 1e-9 {
            frames.append(SessionFixtures.frame(t: t, cents: Double(swing[i % swing.count])))
            t += SessionGrader.hop_s
            i += 1
        }
        var forgiving = GradingSettings()
        forgiving.vibratoExtentCents = 50
        var strict = GradingSettings()
        strict.vibratoExtentCents = 10

        let relaxed = try SessionFixtures.grade(reference: reference, live: frames,
                                                config: forgiving.asGradingConfig)
        let punished = try SessionFixtures.grade(reference: reference, live: frames,
                                                 config: strict.asGradingConfig)
        // Forgiving the wobble vs. reading it as deviation — the setting did this.
        XCTAssertGreaterThan(relaxed.perPhrase?.first?.score ?? 0,
                             punished.perPhrase?.first?.score ?? 1)
    }

    func testTheWeightsSettingReshapesTheSameSessionScore() throws {
        // Two notes where PITCH and SUSTAIN genuinely diverge (score =
        // w.pitch·pitch + w.timing·timing + w.sustain·sustain, C-19):
        //   · note 0 — dead-on pitch but a LATE onset (a 0.5 s hole at the
        //     note's head ⇒ timing ≈ 0, sustain 0.75): pitch-heavy likes it;
        //   · note 1 — on time and held fully but −45c (at the tolerance
        //     edge ⇒ pitch ≈ 0.1, sustain ≈ 1.0): sustain-heavy likes it.
        // The same frames; only the weights decide which config scores higher.
        let reference = SessionFixtures.track(.bass, [
            SessionFixtures.note(0, 2, 60),
            SessionFixtures.note(2.5, 4.5, 62),
        ])
        let live = SessionFixtures.stream(notes: [(0, 2, 6000), (2.5, 4.5, 6155)],
                                          holes: [(0, 0.5)])

        var pitchHeavy = GradingSettings()
        pitchHeavy.weights = GradingWeights(pitch: 0.8, timing: 0.1, sustain: 0.1)
        var sustainHeavy = GradingSettings()
        sustainHeavy.weights = GradingWeights(pitch: 0.1, timing: 0.1, sustain: 0.8)

        let byPitch = try SessionFixtures.grade(reference: reference, live: live,
                                                config: pitchHeavy.asGradingConfig)
        let bySustain = try SessionFixtures.grade(reference: reference, live: live,
                                                  config: sustainHeavy.asGradingConfig)
        XCTAssertNotEqual(byPitch.accuracy?.overall, bySustain.accuracy?.overall)
        // The direction this input promises: the held-but-flat note dominates,
        // so the sustain-heavy config scores it higher.
        XCTAssertGreaterThan(bySustain.accuracy?.overall ?? 0, byPitch.accuracy?.overall ?? 1)
    }

    func testTheSessionRecordsTheSettingsDerivedConfigByValue() throws {
        var settings = GradingSettings()
        settings.toleranceCents = 25
        settings.countIn_beats = 2
        let config = settings.asGradingConfig
        let result = try SessionFixtures.grade(reference: sharpStream.reference,
                                               live: sharpStream.live, config: config)
        // C-18: the result carries the config THAT GRADED it — a grade is
        // always honest about its own terms.
        XCTAssertEqual(result.config, config)
        XCTAssertEqual(result.config?.toleranceCents, 25)
    }
}
