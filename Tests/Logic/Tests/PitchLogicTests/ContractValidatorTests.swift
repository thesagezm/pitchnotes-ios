import XCTest
@testable import PitchLogic

// Contract validator tests (J-004): every V-rule of CONTRACTS v0.0 is asserted
// in both directions — a clean bundle produces ZERO violations, and a
// deliberately mismatched bundle FAILS with the expected rule IDs. This is the
// enforcement proof required by J-002's AC ("a deliberate contract mismatch
// FAILS a logic test").

final class ContractValidatorTests: XCTestCase {

    // MARK: - Fixtures

    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    private func ruleIds(_ violations: [ContractViolation]) -> Set<String> {
        Set(violations.map(\.rule))
    }

    private let validManifest = """
    {
      "contractVersion": "v0.0",
      "engineVersion": "engine-0.0.0",
      "id": "01JDEMO0000000000000000001",
      "title": "Just As I Am",
      "sourceHash": { "algo": "blake3", "hex": "abababababababababababababababababababababababababababababababab" },
      "duration_s": 213.4,
      "sampleRate": 44100,
      "hasInstrumental": true,
      "parts": [
        { "part": "BASS", "stemFile": "stems/BASS.m4a", "channels": 1,
          "notesFile": "notes/BASS.json", "pitchFile": "pitch/BASS.json", "noteConfidence": 0.82 }
      ],
      "confidenceSummary": { "meanNoteConfidence": 0.78 }
    }
    """

    private let validNoteTrack = """
    {
      "contractVersion": "v0.0",
      "part": "BASS",
      "notes": [
        { "start_s": 1.232, "end_s": 2.500, "midi": 48, "cents_ref": 12, "confidence": 0.9 },
        { "start_s": 2.500, "end_s": 4.000, "midi": 50, "cents_ref": -20, "confidence": 0.7 }
      ]
    }
    """

    private let validPitchFrames = """
    {
      "contractVersion": "v0.0",
      "part": "BASS",
      "hopMs": 16,
      "frames": [
        { "t": 0.000, "hz": 0.0,     "confidence": 0.02, "loudness_db": -92.1 },
        { "t": 0.016, "hz": 130.81,  "confidence": 0.85, "loudness_db": -18.0 },
        { "t": 0.032, "hz": 130.93,  "confidence": 0.88, "loudness_db": -17.5 }
      ]
    }
    """

    // MARK: - Happy path (guard against an over-strict validator)

    func testValidManifestHasNoViolations() {
        XCTAssertTrue(ContractValidator.validateManifest(data(validManifest)).isEmpty)
    }

    func testValidNoteTrackHasNoViolations() {
        XCTAssertTrue(ContractValidator.validateNoteTrack(data(validNoteTrack), expectedPart: "BASS").isEmpty)
    }

    func testValidPitchFramesHaveNoViolations() {
        XCTAssertTrue(ContractValidator.validatePitchFrames(data(validPitchFrames), expectedPart: "BASS").isEmpty)
    }

    func testContractVersionConstantMatchesRatifiedContract() {
        // Replaces Leto's SmokeTests placeholder: the logic core pins v0.0.
        XCTAssertEqual(PitchLogicInfo.contractVersion, "v0.0")
    }

    // MARK: - Manifest (C-2.1)

    func testManifestMalformedJSONIsV1() {
        let v = ContractValidator.validateManifest(data("{ not json "))
        XCTAssertEqual(ruleIds(v), ["V1"])
    }

    func testManifestWrongSampleRateIsV4() {
        let bad = validManifest.replacingOccurrences(of: "44100", with: "48000")
        XCTAssertTrue(ruleIds(ContractValidator.validateManifest(data(bad))).contains("V4"))
    }

    func testManifestZeroDurationIsV4() {
        let bad = validManifest.replacingOccurrences(of: "\"duration_s\": 213.4", with: "\"duration_s\": 0.0")
        XCTAssertTrue(ruleIds(ContractValidator.validateManifest(data(bad))).contains("V4"))
    }

    func testManifestWrongHashAlgoIsV5() {
        let bad = validManifest.replacingOccurrences(of: "\"algo\": \"blake3\"", with: "\"algo\": \"md5\"")
        XCTAssertTrue(ruleIds(ContractValidator.validateManifest(data(bad))).contains("V5"))
    }

    func testManifestShortHashHexIsV5() {
        let bad = validManifest.replacingOccurrences(of: "\"hex\": \"abababababababababababababababababababababababababababababababab\"", with: "\"hex\": \"deadbeef\"")
        XCTAssertTrue(ruleIds(ContractValidator.validateManifest(data(bad))).contains("V5"))
    }

    func testManifestUppercaseHashHexIsV5() {
        let bad = validManifest.replacingOccurrences(
            of: "\"hex\": \"abababababababababababababababababababababababababababababababab\"",
            with: "\"hex\": \"ABABABABABABABABABABABABABABABABABABABABABABABABABABABABABABABAB\"")
        XCTAssertTrue(ruleIds(ContractValidator.validateManifest(data(bad))).contains("V5"))
    }

    func testManifestUnknownPartIsV6() {
        let bad = validManifest.replacingOccurrences(of: "\"part\": \"BASS\"", with: "\"part\": \"TENOR\"")
        XCTAssertTrue(ruleIds(ContractValidator.validateManifest(data(bad))).contains("V6"))
    }

    func testManifestDuplicatePartIsV6() {
        let duplicatePart = """
        { "part": "BASS", "stemFile": "stems/BASS2.m4a", "channels": 1,
          "notesFile": "notes/BASS2.json", "noteConfidence": 0.5 }
        """
        let bad = validManifest.replacingOccurrences(
            of: "\"parts\": [",
            with: "\"parts\": [ \(duplicatePart),")
        XCTAssertTrue(ruleIds(ContractValidator.validateManifest(data(bad))).contains("V6"))
    }

    func testManifestStereoVoiceStemIsV3() {
        let bad = validManifest.replacingOccurrences(of: "\"channels\": 1", with: "\"channels\": 2")
        XCTAssertTrue(ruleIds(ContractValidator.validateManifest(data(bad))).contains("V3"))
    }

    func testManifestMissingStemFileIsV2() {
        let bad = validManifest.replacingOccurrences(of: "\"stemFile\": \"stems/BASS.m4a\", ", with: "")
        XCTAssertTrue(ruleIds(ContractValidator.validateManifest(data(bad))).contains("V2"))
    }

    func testManifestNoteConfidenceOutOfRangeIsV12() {
        let bad = validManifest.replacingOccurrences(of: "\"noteConfidence\": 0.82", with: "\"noteConfidence\": 1.5")
        XCTAssertTrue(ruleIds(ContractValidator.validateManifest(data(bad))).contains("V12"))
    }

    // MARK: - NoteTrack (C-2.3)

    func testNoteTrackStartAfterEndIsV7() {
        let bad = validNoteTrack.replacingOccurrences(of: "\"start_s\": 1.232, \"end_s\": 2.500", with: "\"start_s\": 2.500, \"end_s\": 2.500")
        XCTAssertTrue(ruleIds(ContractValidator.validateNoteTrack(data(bad), expectedPart: "BASS")).contains("V7"))
    }

    func testNoteTrackOutOfOrderIsV8() {
        // Second note starts before the first (dedicated literal — no
        // indentation-coupled string surgery; multiline literals strip the
        // closing delimiter's indentation, so \n-joined searches don't match).
        let bad = """
        {
          "contractVersion": "v0.0",
          "part": "BASS",
          "notes": [
            { "start_s": 2.500, "end_s": 4.000, "midi": 50, "cents_ref": -20, "confidence": 0.7 },
            { "start_s": 1.232, "end_s": 2.500, "midi": 48, "cents_ref": 12, "confidence": 0.9 }
          ]
        }
        """
        XCTAssertTrue(ruleIds(ContractValidator.validateNoteTrack(data(bad), expectedPart: "BASS")).contains("V8"))
    }

    func testNoteTrackOverlappingNotesIsV8() {
        let bad = validNoteTrack.replacingOccurrences(of: "\"start_s\": 2.500, \"end_s\": 4.000", with: "\"start_s\": 2.0, \"end_s\": 4.000")
        XCTAssertTrue(ruleIds(ContractValidator.validateNoteTrack(data(bad), expectedPart: "BASS")).contains("V8"))
    }

    func testNoteTrackMidiOutOfRangeIsV9() {
        let bad = validNoteTrack.replacingOccurrences(of: "\"midi\": 48", with: "\"midi\": 120")
        XCTAssertTrue(ruleIds(ContractValidator.validateNoteTrack(data(bad), expectedPart: "BASS")).contains("V9"))
    }

    func testNoteTrackCentsOutOfRangeIsV9() {
        let bad = validNoteTrack.replacingOccurrences(of: "\"cents_ref\": 12", with: "\"cents_ref\": 90")
        XCTAssertTrue(ruleIds(ContractValidator.validateNoteTrack(data(bad), expectedPart: "BASS")).contains("V9"))
    }

    func testNoteTrackConfidenceOutOfRangeIsV9() {
        let bad = validNoteTrack.replacingOccurrences(of: "\"confidence\": 0.9", with: "\"confidence\": 1.5")
        XCTAssertTrue(ruleIds(ContractValidator.validateNoteTrack(data(bad), expectedPart: "BASS")).contains("V9"))
    }

    func testNoteTrackPartFilenameMismatchIsV10() {
        let v = ContractValidator.validateNoteTrack(data(validNoteTrack), expectedPart: "T1")
        XCTAssertEqual(ruleIds(v), ["V10"])
    }

    // MARK: - PitchFrames (C-2.4)

    func testPitchFramesVoicedHzOutOfRangeIsV11() {
        let bad = validPitchFrames.replacingOccurrences(of: "\"hz\": 130.81", with: "\"hz\": 5000.0")
        XCTAssertTrue(ruleIds(ContractValidator.validatePitchFrames(data(bad), expectedPart: "BASS")).contains("V11"))
    }

    func testPitchFramesConfidenceOutOfRangeIsV12() {
        let bad = validPitchFrames.replacingOccurrences(of: "\"confidence\": 0.85", with: "\"confidence\": 1.2")
        XCTAssertTrue(ruleIds(ContractValidator.validatePitchFrames(data(bad), expectedPart: "BASS")).contains("V12"))
    }

    func testPitchFramesNonUniformGridIsV13() {
        let bad = validPitchFrames.replacingOccurrences(of: "\"t\": 0.032", with: "\"t\": 0.5")
        XCTAssertTrue(ruleIds(ContractValidator.validatePitchFrames(data(bad), expectedPart: "BASS")).contains("V13"))
    }

    func testPitchFramesDecreasingTIsV13() {
        let bad = validPitchFrames.replacingOccurrences(of: "\"t\": 0.032", with: "\"t\": 0.010")
        XCTAssertTrue(ruleIds(ContractValidator.validatePitchFrames(data(bad), expectedPart: "BASS")).contains("V13"))
    }

    func testPitchFramesWrongHopIsV1() {
        let bad = validPitchFrames.replacingOccurrences(of: "\"hopMs\": 16", with: "\"hopMs\": 32")
        XCTAssertTrue(ruleIds(ContractValidator.validatePitchFrames(data(bad), expectedPart: "BASS")).contains("V1"))
    }

    func testPitchFramesPartFilenameMismatchIsV10() {
        let v = ContractValidator.validatePitchFrames(data(validPitchFrames), expectedPart: "T2")
        XCTAssertEqual(ruleIds(v), ["V10"])
    }

    // MARK: - Deliberate aggregate mismatch (J-002 AC: mismatch FAILS)

    /// The corrupt bundle shape the preview stub ships as "Mismatch Demo (must
    /// FAIL)": violations across V3/V4/V5 + V7/V8/V9 + V11/V12/V13 in ONE file
    /// set. Asserts the validator catches the spread — proving the contract is
    /// actually enforced, not decorative.
    func testDeliberateMismatchBundleFailsAcrossRules() {
        let corruptManifest = """
        {
          "contractVersion": "v0.0",
          "engineVersion": "engine-0.0.0",
          "id": "01JDEMO0000000000000000002",
          "title": "Mismatch Demo (must FAIL)",
          "sourceHash": { "algo": "blake3", "hex": "deadbeef" },
          "duration_s": 0.0,
          "sampleRate": 44100,
          "hasInstrumental": false,
          "parts": [
            { "part": "BASS", "stemFile": "stems/BASS.m4a", "channels": 2,
              "notesFile": "notes/BASS.json", "noteConfidence": 0.9 }
          ],
          "confidenceSummary": { "meanNoteConfidence": 0.9 }
        }
        """
        let manifestRules = ruleIds(ContractValidator.validateManifest(data(corruptManifest)))
        XCTAssertTrue(manifestRules.contains("V4"), "zero duration must fail V4")
        XCTAssertTrue(manifestRules.contains("V5"), "short hash must fail V5")
        XCTAssertTrue(manifestRules.contains("V3"), "stereo voice stem must fail V3")

        let corruptNotes = """
        {
          "contractVersion": "v0.0",
          "part": "T1",
          "notes": [
            { "start_s": 2.8, "end_s": 2.8, "midi": 120, "cents_ref": 0, "confidence": 1.5 },
            { "start_s": 1.0, "end_s": 4.5, "midi": 62, "cents_ref": 0, "confidence": 0.9 }
          ]
        }
        """
        let noteRules = ruleIds(ContractValidator.validateNoteTrack(data(corruptNotes), expectedPart: "T1"))
        XCTAssertTrue(noteRules.contains("V7"), "start >= end must fail V7")
        XCTAssertTrue(noteRules.contains("V8"), "out-of-order/overlap must fail V8")
        XCTAssertTrue(noteRules.contains("V9"), "midi 120 + confidence 1.5 must fail V9")

        let corruptPitch = """
        {
          "contractVersion": "v0.0",
          "part": "T1",
          "hopMs": 16,
          "frames": [
            { "t": 0.000, "hz": 440.0, "confidence": 0.9, "loudness_db": -18.0 },
            { "t": 0.016, "hz": 5000.0, "confidence": 1.2, "loudness_db": -18.0 },
            { "t": 1.500, "hz": 442.0, "confidence": 0.9, "loudness_db": -18.0 }
          ]
        }
        """
        let pitchRules = ruleIds(ContractValidator.validatePitchFrames(data(corruptPitch), expectedPart: "T1"))
        XCTAssertTrue(pitchRules.contains("V11"), "hz 5000 must fail V11")
        XCTAssertTrue(pitchRules.contains("V12"), "confidence 1.2 must fail V12")
        XCTAssertTrue(pitchRules.contains("V13"), "non-uniform grid must fail V13")
    }
}
