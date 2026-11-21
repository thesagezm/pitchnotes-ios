import XCTest
@testable import EngineCore

/// V-rule validator tests (CONTRACTS v0.0 V1–V13). Rule IDs are contractual —
/// J-004 (Jess) tests the same rules from the PitchLogic side.
final class ValidatorTests: XCTestCase {

    // MARK: - Fixtures

    private func goodManifest() -> SongManifest {
        SongManifest(
            engineVersion: "engine-mock-0.0.0",
            id: "01JTESTTESTTESTTESTTESTTE",
            title: "Test",
            sourceHash: SourceHash(hex: String(repeating: "0123456789abcdef", count: 4)),
            duration_s: 12.0,
            sampleRate: 44100,
            hasInstrumental: false,
            parts: [PartInfo(part: .bass, stemFile: "stems/BASS.m4a", channels: 1,
                             notesFile: "notes/BASS.json", pitchFile: nil, noteConfidence: 0.9)],
            confidenceSummary: ConfidenceSummary(meanNoteConfidence: 0.9)
        )
    }

    private func goodNote(_ midi: Int = 48) -> Note {
        Note(start_s: 0.0, end_s: 1.0, midi: midi, cents_ref: 0, confidence: 0.9)
    }

    private func frame(_ i: Int, hz: Double = 130.0, confidence: Double = 0.9) -> PitchFrame {
        PitchFrame(t: Double(i) * 0.016, hz: hz, confidence: confidence, loudness_db: -30)
    }

    // MARK: - V4/V5/V6 (manifest)

    func testV4DurationAndSampleRate() {
        var m = goodManifest()
        m.duration_s = 0
        XCTAssertFalse(BundleValidator.validate(manifest: m).isValid)
        m.duration_s = -1
        XCTAssertFalse(BundleValidator.validate(manifest: m).isValid)
        m.duration_s = 12.0
        m.sampleRate = 48000
        XCTAssertFalse(BundleValidator.validate(manifest: m).isValid)
    }

    func testV5SourceHash() {
        var m = goodManifest()
        m.sourceHash.algo = "sha256"
        XCTAssertFalse(BundleValidator.validate(manifest: m).isValid)
        m.sourceHash.algo = "blake3"
        m.sourceHash.hex = String(repeating: "a", count: 63)
        XCTAssertFalse(BundleValidator.validate(manifest: m).isValid)
        m.sourceHash.hex = String(repeating: "A", count: 64) // uppercase rejected
        XCTAssertFalse(BundleValidator.validate(manifest: m).isValid)
        m.sourceHash.hex = "not-hex"
        XCTAssertFalse(BundleValidator.validate(manifest: m).isValid)
        m.sourceHash.hex = String(repeating: "0123456789abcdef", count: 4)
        XCTAssertTrue(BundleValidator.validate(manifest: m).isValid)
    }

    func testV6UniqueParts() {
        var m = goodManifest()
        m.parts.append(PartInfo(part: .bass, stemFile: "stems/BASS2.m4a", channels: 1,
                                notesFile: "notes/BASS2.json", noteConfidence: 0.9))
        XCTAssertFalse(BundleValidator.validate(manifest: m).isValid)
        var empty = goodManifest()
        empty.parts = []
        XCTAssertFalse(BundleValidator.validate(manifest: empty).isValid)
    }

    func testV3DeclaredChannelPolicy() {
        var m = goodManifest()
        m.parts[0].channels = 2 // voice stem must be mono (D-8)
        XCTAssertFalse(BundleValidator.validate(manifest: m).isValid)
        m.parts[0].part = .instrumental
        m.parts[0].channels = 1 // instrumental must be stereo (D-8)
        XCTAssertFalse(BundleValidator.validate(manifest: m).isValid)
    }

    // MARK: - V7/V8/V9 (NoteTrack)

    func testV7StartBeforeEnd() {
        var bad = NoteTrack(part: .bass, notes: [goodNote()])
        bad.notes[0] = Note(start_s: 1.0, end_s: 1.0, midi: 48, confidence: 0.9)
        XCTAssertFalse(BundleValidator.validate(noteTrack: bad).isValid)
    }

    func testV8SortedAndNonOverlapping() {
        var overlap = NoteTrack(part: .bass, notes: [
            Note(start_s: 0.0, end_s: 2.0, midi: 48, confidence: 0.9),
            Note(start_s: 1.5, end_s: 3.0, midi: 50, confidence: 0.9),
        ])
        XCTAssertFalse(BundleValidator.validate(noteTrack: overlap).isValid)

        let unsorted = NoteTrack(part: .bass, notes: [
            Note(start_s: 3.0, end_s: 4.0, midi: 48, confidence: 0.9),
            Note(start_s: 0.0, end_s: 1.0, midi: 48, confidence: 0.9),
        ])
        XCTAssertFalse(BundleValidator.validate(noteTrack: unsorted).isValid)

        let touching = NoteTrack(part: .bass, notes: [
            Note(start_s: 0.0, end_s: 2.0, midi: 48, confidence: 0.9),
            Note(start_s: 2.0, end_s: 3.0, midi: 50, confidence: 0.9),
        ])
        XCTAssertTrue(BundleValidator.validate(noteTrack: touching).isValid)
    }

    func testV9Ranges() {
        var t = NoteTrack(part: .bass, notes: [goodNote(23)])
        XCTAssertFalse(BundleValidator.validate(noteTrack: t).isValid)
        t.notes[0].midi = 97
        XCTAssertFalse(BundleValidator.validate(noteTrack: t).isValid)
        t.notes[0].midi = 48
        t.notes[0].cents_ref = 51
        XCTAssertFalse(BundleValidator.validate(noteTrack: t).isValid)
        t.notes[0].cents_ref = -51
        XCTAssertFalse(BundleValidator.validate(noteTrack: t).isValid)
        t.notes[0].cents_ref = 0
        t.notes[0].confidence = 1.1
        XCTAssertFalse(BundleValidator.validate(noteTrack: t).isValid)
    }

    // MARK: - V11/V12/V13 (PitchFrames)

    func testV11VoicedRange() {
        var f = PitchFramesFile(part: .bass, frames: [frame(0, hz: 30.0)])
        XCTAssertFalse(BundleValidator.validate(pitchFrames: f).isValid)
        f.frames = [frame(0, hz: 3000.0)]
        XCTAssertFalse(BundleValidator.validate(pitchFrames: f).isValid)
        f.frames = [frame(0, hz: 0.0)] // unvoiced is valid
        XCTAssertTrue(BundleValidator.validate(pitchFrames: f).isValid)
        f.frames = [frame(0, hz: 46.9), frame(1, hz: 2093.75)]
        XCTAssertTrue(BundleValidator.validate(pitchFrames: f).isValid)
    }

    func testV12ConfidenceRange() {
        let f = PitchFramesFile(part: .bass, frames: [frame(0, confidence: 1.2)])
        XCTAssertFalse(BundleValidator.validate(pitchFrames: f).isValid)
    }

    func testV13UniformGrid() {
        // Off-grid t (beyond 1 ms tolerance).
        let offGrid = PitchFramesFile(part: .bass, frames: [
            PitchFrame(t: 0.0, hz: 0.0, confidence: 0.5, loudness_db: -30),
            PitchFrame(t: 0.02, hz: 0.0, confidence: 0.5, loudness_db: -30),
        ])
        XCTAssertFalse(BundleValidator.validate(pitchFrames: offGrid).isValid)

        // Non-increasing t.
        let duplicate = PitchFramesFile(part: .bass, frames: [
            PitchFrame(t: 0.016, hz: 0.0, confidence: 0.5, loudness_db: -30),
            PitchFrame(t: 0.016, hz: 0.0, confidence: 0.5, loudness_db: -30),
        ])
        XCTAssertFalse(BundleValidator.validate(pitchFrames: duplicate).isValid)
    }

    func testWrongHopMsRejected() {
        let f = PitchFramesFile(part: .bass, hopMs: 10, frames: [frame(0)])
        XCTAssertFalse(BundleValidator.validate(pitchFrames: f).isValid)
    }

    // MARK: - Directory-level (V1/V2/V3-reality/V10)

    func testV1MissingOrBrokenSongJSON() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("enginecore-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertFalse(BundleValidator.validate(bundleDirectory: dir).isValid) // V1 missing
        try Data("not json".utf8).write(to: dir.appendingPathComponent("song.json"))
        XCTAssertFalse(BundleValidator.validate(bundleDirectory: dir).isValid) // V1 unparseable
    }

    func testV2MissingStemFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("enginecore-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var m = goodManifest()
        m.parts[0].stemFile = "stems/BASS.m4a"
        try JSONEncoder().encode(m).write(to: dir.appendingPathComponent("song.json"))
        let result = BundleValidator.validate(bundleDirectory: dir)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.violations.contains { $0.rule == "V2" })
    }

    func testWavChannelCountHeaderParse() throws {
        // Use the MockEngine's own writer: voice stems are mono (V3/D-8 reality).
        let engine = MockEngine(scenario: .perfect, seed: 42)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("enginecore-tests-\(UUID().uuidString)", isDirectory: true)
        _ = try engine.makeBundle(to: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stem = dir.appendingPathComponent("stems/BASS.wav")
        XCTAssertEqual(BundleValidator.wavChannelCount(url: stem), 1)
        // Non-WAV input returns nil (no false V3 failure).
        XCTAssertEqual(BundleValidator.wavChannelCount(url: dir.appendingPathComponent("song.json")), nil)
    }
}
