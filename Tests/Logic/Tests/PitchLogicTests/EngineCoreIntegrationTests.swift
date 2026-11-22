// EngineCoreIntegrationTests (X-006) — Jess's lane consuming Paul's EngineCore
// through the Tests/Logic package dependency. Proves the X-003/X-006 topology:
//   1. Part round-trip vs EngineCore (X-006 AC) + one display-name mapping.
//   2. MockEngine bundle on disk → EngineCore.BundleValidator → CLEAN, and a
//      deliberately tampered bundle → CAUGHT (the J-002 "mismatch fails a
//      test" proof, now on Paul's real bundle + real validators, not the
//      deleted JSON shim).
//   3. PitchMath (Jess) validates MockEngine scenario deviations (Paul) —
//      the ribbon's cents math (J-101) agrees with the mock's generator.
//   4. UnisonDetector (UX §3.7) unit tests.
//
// NOT duplicated here: V1–V13 per-rule matrix and scenario-by-scenario
// deviation asserts live in Engine/Tests (Paul's suite, CI `cd Engine && swift
// test`). This suite is the cross-lane seam.

import XCTest
import PitchLogic
import EngineCore

final class EngineCoreIntegrationTests: XCTestCase {

    // MARK: - 1 · Part round-trip vs EngineCore (X-006 AC)

    func testPartRoundTripViaEngineCoreCodable() throws {
        for part in Part.allCases {
            let data = try JSONEncoder().encode(part)
            let decoded = try JSONDecoder().decode(Part.self, from: data)
            XCTAssertEqual(decoded, part, "\(part.rawValue) must round-trip through Codable")
            XCTAssertEqual(decoded.rawValue, part.rawValue)
        }
        // Raw values are STABLE FOREVER (CONTRACTS C-1) — guard the spellings
        // Jess's UI depends on.
        XCTAssertEqual(Part.bass.rawValue, "BASS")
        XCTAssertEqual(Part.t1.rawValue, "T1")
        XCTAssertEqual(Part.baritenor.rawValue, "BARITENOR")
    }

    func testPartSortOrderAndComparableMatchContract() {
        // C-1 numeric sortOrder (UI/display): soprano < alto < t1 < t2 <
        // baritenor < baritone < bass < vp < lead < instrumental < vocals
        // (vocals = v1.0 C-1/L-203, sortOrder 10, appended — additive rule).
        // Comparable uses sortOrder (v0.0.1 clarification D-18.4).
        let expected: [Part] = [.soprano, .alto, .t1, .t2, .baritenor, .baritone, .bass, .vp, .lead, .instrumental, .vocals]
        XCTAssertEqual(Part.allCases.sorted(), expected)
        XCTAssertTrue(Part.t1 < Part.bass, "Comparable is display order, NOT pitch order")
    }

    func testPartDisplayNamesCoverAllCases() {
        for part in Part.allCases {
            XCTAssertFalse(part.displayName.isEmpty, "\(part.rawValue) needs a display name")
        }
        XCTAssertEqual(Part.bass.displayName, "Bass")
        XCTAssertEqual(Part.t2.displayName, "T2")
    }

    // MARK: - 2 · MockEngine bundle → EngineCore validators (clean + tampered)

    /// Fresh temp directory per call — MockEngine.makeBundle refuses non-empty
    /// foreign directories by design.
    private func makeMockBundle(scenario: MockScenario, seed: UInt64) throws -> (engine: MockEngine, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("x006-\(UUID().uuidString)", isDirectory: true)
        let engine = MockEngine(scenario: scenario, seed: seed, referencePart: .bass, bundleDirectory: dir)
        _ = try engine.makeBundle(to: dir)
        return (engine, dir)
    }

    func testMockBundlesOnDiskPassBundleValidatorForAllScenarios() throws {
        for scenario in MockScenario.allCases {
            let (_, dir) = try makeMockBundle(scenario: scenario, seed: 0x5017)
            let result = BundleValidator.validate(bundleDirectory: dir)
            XCTAssertTrue(result.isValid, "\(scenario.rawValue) bundle must be V1–V13 clean: \(result.violations)")
        }
    }

    func testTamperedNoteMidiIsCaughtAsV9() throws {
        let (_, dir) = try makeMockBundle(scenario: .perfect, seed: 0x5020)

        // Tamper on disk: first T1 note jumps to midi 120 (outside V9's 24–96).
        let notesURL = dir.appendingPathComponent("notes/T1.json")
        var track = try JSONDecoder().decode(NoteTrack.self, from: Data(contentsOf: notesURL))
        track.notes[0].midi = 120
        try JSONEncoder().encode(track).write(to: notesURL)

        let result = BundleValidator.validate(bundleDirectory: dir)
        XCTAssertFalse(result.isValid, "tampered bundle must FAIL validation")
        XCTAssertTrue(result.violations.contains { $0.rule == "V9" },
                      "midi 120 must trip V9, got: \(result.violations)")
    }

    func testTamperedManifestDurationIsCaughtAsV4() throws {
        let (_, dir) = try makeMockBundle(scenario: .perfect, seed: 0x5021)

        let manifestURL = dir.appendingPathComponent("song.json")
        var manifest = try JSONDecoder().decode(SongManifest.self, from: Data(contentsOf: manifestURL))
        manifest.duration_s = 0.0 // V4: duration_s must be > 0
        try JSONEncoder().encode(manifest).write(to: manifestURL)

        let result = BundleValidator.validate(bundleDirectory: dir)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.violations.contains { $0.rule == "V4" },
                      "duration 0 must trip V4, got: \(result.violations)")
    }

    // MARK: - 3 · PitchMath (Jess) ↔ MockEngine scenarios (Paul)

    /// The ribbon consumes `livePitch` frames and computes deviation with
    /// PitchMath.centsRef. This asserts both lanes agree on the scripted
    /// deviations at a note-center instant (cross-lane contract for J-101).
    func testLivePitchDeviationsAgreeWithPitchMath() throws {
        // Bass script note at t = 1.0 s is midi 48 (MockEngine.script).
        let chunk = MicChunk(samples: [], sampleRate: 16000, captureTime_s: 1.0)

        let flat = MockEngine(scenario: .flat, seed: 0x5022, referencePart: .bass)
        let flatFrame = flat.livePitch(chunk)
        let flatDev = PitchMath.centsRef(hz: flatFrame.hz, midi: 48)
        XCTAssertEqual(flatDev, -30.0, accuracy: 0.5, "flat scenario must be −30¢ per PitchMath")

        let sharp = MockEngine(scenario: .sharp, seed: 0x5023, referencePart: .bass)
        let sharpDev = PitchMath.centsRef(hz: sharp.livePitch(chunk).hz, midi: 48)
        XCTAssertEqual(sharpDev, 35.0, accuracy: 0.5, "sharp scenario must be +35¢ per PitchMath")

        let octave = MockEngine(scenario: .octaveError, seed: 0x5024, referencePart: .bass)
        let octaveDev = PitchMath.centsRef(hz: octave.livePitch(chunk).hz, midi: 48)
        XCTAssertEqual(octaveDev, 1200.0, accuracy: 0.5, "octaveError must sit +1200¢ (one octave high)")

        XCTAssertTrue(PitchMath.isOctaveError(octaveDev, tolerance: 50),
                      "ribbon octave-error detection (UX §3.4) must fire on the mock's octave scenario")
        XCTAssertFalse(PitchMath.isOctaveError(flatDev, tolerance: 50))
    }

    func testSilentScenarioLivePitchIsUnvoiced() {
        let chunk = MicChunk(samples: [], sampleRate: 16000, captureTime_s: 1.0)
        let silent = MockEngine(scenario: .silent, seed: 0x5025, referencePart: .bass)
        let frame = silent.livePitch(chunk)
        XCTAssertEqual(frame.hz, 0.0, "silent scenario = unvoiced (hz 0, C-2.4)")
        XCTAssertNil(PitchMath.midiNearest(forHz: frame.hz), "unvoiced input yields no MIDI note")
    }

    func testVibratoScenarioStaysWithinTwentyFiveCentsOfPitchMath() throws {
        let vibrato = MockEngine(scenario: .vibrato, seed: 0x5026, referencePart: .bass)
        // Bass note 0 spans t 0.0–2.8 s (midi 48); sample interior instants.
        for t in stride(from: 0.2, through: 2.6, by: 0.1) {
            let frame = vibrato.livePitch(MicChunk(samples: [], sampleRate: 16000, captureTime_s: t))
            let dev = PitchMath.centsRef(hz: frame.hz, midi: 48)
            XCTAssertLessThanOrEqual(abs(dev), 25.0 + 0.5, "vibrato ±25¢ @5.5 Hz violated at t=\(t)")
        }
    }

    // MARK: - 4 · UnisonDetector (UX §3.7)

    private func note(_ start: Double, _ end: Double, _ midi: Int, cents: Int = 0) -> Note {
        Note(start_s: start, end_s: end, midi: midi, cents_ref: cents, confidence: 0.9)
    }

    func testUnisonDetectedForOverlappingSamePitchNotes() {
        let tracks: [Part: NoteTrack] = [
            .t1: NoteTrack(part: .t1, notes: [note(0, 2, 60)]),
            .t2: NoteTrack(part: .t2, notes: [note(0, 2, 60)]),
        ]
        XCTAssertEqual(UnisonDetector.pairs(in: tracks).count, 1)
        XCTAssertEqual(UnisonDetector.pairs(in: tracks).first?.first, .t1, "pairs ordered by sortOrder (T1 first)")
        XCTAssertEqual(UnisonDetector.pairs(in: tracks).first?.second, .t2)
    }

    func testUnisonDetectedForSemitoneAdjacentOverlap() {
        // |Δcents| = 100 exactly — still flagged (deliberately conservative).
        let tracks: [Part: NoteTrack] = [
            .t1: NoteTrack(part: .t1, notes: [note(1.0, 3.0, 61)]),
            .bass: NoteTrack(part: .bass, notes: [note(2.0, 4.0, 60)]),
        ]
        XCTAssertEqual(UnisonDetector.pairs(in: tracks).count, 1)
    }

    func testNoUnisonWhenNotesDoNotOverlapInTimeOrPitch() {
        let tracks: [Part: NoteTrack] = [
            .t1: NoteTrack(part: .t1, notes: [note(0, 1, 60)]),
            .t2: NoteTrack(part: .t2, notes: [note(2, 3, 60)]), // time gap
            .bass: NoteTrack(part: .bass, notes: [note(0, 1, 48)]), // pitch gap > 100¢
        ]
        XCTAssertTrue(UnisonDetector.pairs(in: tracks).isEmpty)
    }

    func testCentsRefBreaksTieAtExactHundredCents() {
        // 60 + 50¢ vs 61 − 50¢ → Δ = 100 → unison-risk (boundary inclusive).
        let tracks: [Part: NoteTrack] = [
            .t1: NoteTrack(part: .t1, notes: [note(0, 2, 60, cents: 50)]),
            .t2: NoteTrack(part: .t2, notes: [note(0, 2, 61, cents: -50)]),
        ]
        XCTAssertEqual(UnisonDetector.pairs(in: tracks).count, 1)
    }

    func testUnisonDetectorIgnoresEmptyAndNonSingableParts() {
        let tracks: [Part: NoteTrack] = [
            .t1: NoteTrack(part: .t1, notes: []),
            .instrumental: NoteTrack(part: .instrumental, notes: [note(0, 2, 60)]),
            .vp: NoteTrack(part: .vp, notes: [note(0, 2, 60)]),
        ]
        XCTAssertTrue(UnisonDetector.pairs(in: tracks).isEmpty)
    }

    func testUnisonLabelUsesDisplayNames() {
        let pair = UnisonPair(first: .t1, second: .t2)
        XCTAssertEqual(UnisonDetector.label(for: pair), "T1 ↔ T2")
    }

    func testMockScriptVoicingsHaveNoUnisonButDetectorFindsSyntheticOverlap() throws {
        // MockEngine's scripted voicings are SPREAD (no two same-time notes
        // within 100¢) — the honest catalog shows NO unison chips, and the
        // detector must agree with that. Then a synthetic overlap proves the
        // detector fires on real NoteTrack shapes (UX §3.7 affordance).
        let (engine, _) = try makeMockBundle(scenario: .perfect, seed: 0x5027)
        let ensemble: [Part] = [.bass, .baritone, .baritenor, .t2, .t1] // mock ensemble (C-1 raws)
        var tracks: [Part: NoteTrack] = [:]
        for part in ensemble {
            tracks[part] = engine.noteTrack(for: part)
        }
        XCTAssertTrue(UnisonDetector.pairs(in: tracks).isEmpty,
                      "spread mock voicings must not be flagged as unison")

        // Synthetic: give T2 T1's pitches (same time, same pitch) → pair found.
        var overlapped = tracks
        overlapped[.t2] = NoteTrack(part: .t2, notes: (tracks[.t1]?.notes ?? []).map {
            Note(start_s: $0.start_s, end_s: $0.end_s, midi: $0.midi,
                 cents_ref: $0.cents_ref, confidence: $0.confidence)
        })
        let pairs = UnisonDetector.pairs(in: overlapped)
        XCTAssertTrue(pairs.contains(UnisonPair(first: .t1, second: .t2)),
                      "T2 cloning T1's notes must surface the unison pair")
    }
}
