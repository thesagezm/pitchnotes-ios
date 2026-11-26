import XCTest
import EngineCore
@testable import PitchLogic

// J-301 piano-roll logic tests: the D-41 confidence bands, phrase presence,
// unison derivation, the time/pitch geometry, culling, hit-testing, the
// region loop, and the display-only transpose.

final class PianoRollModelTests: XCTestCase {

    private func note(_ start: Double, _ end: Double, _ midi: Int,
                      cents: Int = 0, confidence: Double = 0.9) -> Note {
        Note(start_s: start, end_s: end, midi: midi, cents_ref: cents, confidence: confidence)
    }

    private func track(_ part: Part, _ notes: [Note]) -> NoteTrack {
        NoteTrack(part: part, notes: notes)
    }

    // MARK: - Confidence bands (D-41 §1)

    func testBandThresholdsAreD41Verbatim() {
        XCTAssertEqual(ConfidenceBand(confidence: 0.80), .confirmed)
        XCTAssertEqual(ConfidenceBand(confidence: 1.0), .confirmed)
        XCTAssertEqual(ConfidenceBand(confidence: 0.79), .provisional)
        XCTAssertEqual(ConfidenceBand(confidence: 0.50), .provisional)
        XCTAssertEqual(ConfidenceBand(confidence: 0.49), .unassigned)
        XCTAssertEqual(ConfidenceBand(confidence: 0.0), .unassigned)
    }

    func testOnlyUnassignedNotesAreHeldBackFromGrading() {
        XCTAssertTrue(ConfidenceBand.confirmed.isGradedByDefault)
        XCTAssertTrue(ConfidenceBand.provisional.isGradedByDefault)
        XCTAssertFalse(ConfidenceBand.unassigned.isGradedByDefault,
                       "D-41 §1: c < 0.50 is excluded from grading by default (J-302 can force-assign)")
    }

    func testModelBandsEachNote() {
        let model = PianoRollModel(tracks: [
            .t1: track(.t1, [note(0, 1, 72, confidence: 0.95),
                             note(4, 5, 72, confidence: 0.65),
                             note(8, 9, 72, confidence: 0.20)])
        ], duration_s: 12)
        XCTAssertEqual(model.notes.map(\.band), [.confirmed, .provisional, .unassigned])
    }

    // MARK: - Phrase presence (D-41 §2)

    func testPartIsPresentWhenMeanConfidenceIsAtLeast060() {
        let model = PianoRollModel(tracks: [
            .t1: track(.t1, [note(0, 1, 72, confidence: 0.60)]),
        ], duration_s: 8)
        XCTAssertTrue(model.isPresent(part: .t1, phraseIndex: 0),
                      "D-41 §2: mean confidence 0.60 is present")
    }

    func testPartIsAbsentBelow060ButStillRendered() {
        let model = PianoRollModel(tracks: [
            .t1: track(.t1, [note(0, 1, 72, confidence: 0.59)]),
        ], duration_s: 8)
        XCTAssertFalse(model.isPresent(part: .t1, phraseIndex: 0))
        XCTAssertEqual(model.visibleParts, [.t1],
                       "D-41 §2: an ABSENT part is dimmed, NEVER hidden")
    }

    func testPartWithNoNotesInPhraseIsAbsent() {
        let model = PianoRollModel(tracks: [
            .t1: track(.t1, [note(0, 1, 72)]),
        ], duration_s: 8)
        XCTAssertFalse(model.isPresent(part: .t1, phraseIndex: 1))
        XCTAssertEqual(model.presence(part: .t1, phraseIndex: 1)?.noteCount, 0)
    }

    func testPhrasesAreFourSecondSpansWithoutAScore() {
        let model = PianoRollModel(tracks: [:], duration_s: 10)
        XCTAssertEqual(model.phrases.count, 3)
        XCTAssertEqual(model.phrases[0].start_s, 0)
        XCTAssertEqual(model.phrases[0].end_s, 4.0, accuracy: 1e-9)
        XCTAssertEqual(model.phrases[2].end_s, 12.0, accuracy: 1e-9)
    }

    func testBarAlignedPhrasesWhenAScoreSuppliedABarMap() {
        let model = PianoRollModel(tracks: [:], duration_s: 20, barStarts: [0, 2, 6, 10])
        XCTAssertEqual(model.phrases.count, 4)
        XCTAssertEqual(model.phrases[1].start_s, 2, accuracy: 1e-9)
        XCTAssertEqual(model.phrases[1].end_s, 6, accuracy: 1e-9)
        XCTAssertEqual(model.phrases[3].end_s, 20, accuracy: 1e-9)
    }

    // MARK: - Unison (D-41 §3)

    func testSamePitchInTwoPartsInOnePhraseIsUnison() {
        let model = PianoRollModel(tracks: [
            .t1: track(.t1, [note(0, 2, 62, cents: 4)]),
            .t2: track(.t2, [note(0.5, 2, 62, cents: -6)]),
        ], duration_s: 8)
        XCTAssertTrue(model.notes.allSatisfy(\.isUnison),
                      "D-41 §3: same MIDI within ±25 ¢ across parts ⇒ unison")
    }

    func testPitchMoreThan25CentsApartIsNotUnison() {
        let model = PianoRollModel(tracks: [
            .t1: track(.t1, [note(0, 2, 62, cents: 0)]),
            .t2: track(.t2, [note(0, 2, 62, cents: 30)]),
        ], duration_s: 8)
        XCTAssertFalse(model.notes.contains(where: \.isUnison),
                       "D-41 §3: 30 ¢ apart is outside the ±25 ¢ unison window")
    }

    func testSamePitchInDifferentPhrasesIsNotUnison() {
        let model = PianoRollModel(tracks: [
            .t1: track(.t1, [note(0, 2, 62)]),
            .t2: track(.t2, [note(5, 7, 62)]),
        ], duration_s: 12)
        XCTAssertFalse(model.notes.contains(where: \.isUnison))
    }

    func testTwoNotesOfTheSamePartAreNotUnison() {
        let model = PianoRollModel(tracks: [
            .t1: track(.t1, [note(0, 2, 62), note(0.2, 1.5, 62)]),
        ], duration_s: 8)
        XCTAssertFalse(model.notes.contains(where: \.isUnison))
    }

    // MARK: - Geometry (UX §3.2/§3.3)

    func testTimeAndPitchMappingsRoundTrip() {
        let layout = PianoRollLayout(pixelsPerSecond: 90, pixelsPerSemitone: 12,
                                     scrollSeconds: 3, topCents: 8000,
                                     viewportWidth: 390, viewportHeight: 500)
        XCTAssertEqual(layout.time(forX: layout.x(forTime: 12.5)), 12.5, accuracy: 1e-9)
        XCTAssertEqual(layout.cents(forY: layout.y(forCents: 6100)), 6100, accuracy: 1e-9)
        XCTAssertEqual(layout.x(forTime: 3), 0, accuracy: 1e-9)
    }

    func testVisibleTimeRangeFollowsTheViewport() {
        let layout = PianoRollLayout(pixelsPerSecond: 90, pixelsPerSemitone: 12,
                                     scrollSeconds: 10, topCents: 8000,
                                     viewportWidth: 360, viewportHeight: 500)
        XCTAssertEqual(layout.visibleTimeRange.lowerBound, 10, accuracy: 1e-9)
        XCTAssertEqual(layout.visibleTimeRange.upperBound, 14, accuracy: 1e-9)
    }

    func testHitTestFindsTheNoteUnderThePoint() {
        let model = PianoRollModel(tracks: [
            .t1: track(.t1, [note(1, 2, 72)]),
        ], duration_s: 8)
        let layout = PianoRollLayout(pixelsPerSecond: 100, pixelsPerSemitone: 12,
                                     scrollSeconds: 0, topCents: 8000,
                                     viewportWidth: 400, viewportHeight: 400)
        let target = model.notes[0]
        let rect = model.rect(for: target, layout: layout)
        let hit = model.hitTest(x: rect.centerX, y: rect.centerY, layout: layout)
        XCTAssertEqual(hit?.id, target.id)
    }

    func testHitTestIgnoresHiddenParts() {
        var model = PianoRollModel(tracks: [
            .t1: track(.t1, [note(1, 2, 72)]),
        ], duration_s: 8)
        let layout = PianoRollLayout(pixelsPerSecond: 100, pixelsPerSemitone: 12,
                                     scrollSeconds: 0, topCents: 8000,
                                     viewportWidth: 400, viewportHeight: 400)
        let rect = model.rect(for: model.notes[0], layout: layout)
        model.hiddenParts = [.t1]
        XCTAssertNil(model.hitTest(x: rect.centerX, y: rect.centerY, layout: layout))
    }

    func testCullingKeepsOnlyTheVisibleWindow() {
        let model = PianoRollModel(tracks: [
            .t1: track(.t1, (0..<200).map { note(Double($0) * 2, Double($0) * 2 + 1, 60) }),
        ], duration_s: 400)
        let visible = model.notes(inTimeRange: 0...10)
        XCTAssertEqual(visible.count, 6, "only the notes in the window are drawn (60 fps target)")
        XCTAssertEqual(model.notes.count, 200)
    }

    // MARK: - Region loop (drag across notes)

    func testLoopRegionIsOrderIndependentAndClampedToTheSong() {
        let model = PianoRollModel(tracks: [:], duration_s: 30)
        let layout = PianoRollLayout(pixelsPerSecond: 100, pixelsPerSemitone: 12,
                                     scrollSeconds: 0, topCents: 8000,
                                     viewportWidth: 400, viewportHeight: 400)
        let region = model.loopRegion(fromX: 200, toX: 50, layout: layout)
        XCTAssertEqual(region.start_s, 0.5, accuracy: 1e-9)
        XCTAssertEqual(region.end_s, 2.0, accuracy: 1e-9)
        let clamped = model.loopRegion(fromX: -100, toX: 99999, layout: layout)
        XCTAssertEqual(clamped.start_s, 0, accuracy: 1e-9)
        XCTAssertEqual(clamped.end_s, 30, accuracy: 1e-9)
    }

    // MARK: - Transpose (display only, clamped — UX §A.2.4)

    func testTransposeMovesTheDisplayOnly() {
        let original = track(.t1, [note(0, 1, 72, cents: 3)])
        let model = PianoRollModel(tracks: [.t1: original], duration_s: 8, transposeSemitones: 2)
        XCTAssertEqual(model.notes[0].note.midi, 72, "the TRACK is never mutated")
        XCTAssertEqual(model.notes[0].note.cents_ref, 3)
        XCTAssertEqual(model.displayedMidi(for: model.notes[0]), 74)
    }

    func testTransposeIsClampedToThePartRange() {
        let model = PianoRollModel(tracks: [
            .t1: track(.t1, [note(0, 1, 76)]),
        ], duration_s: 8, transposeSemitones: 6)
        // C-6.1 T1 preset tops out at MIDI 76 — a +6 transpose cannot leave
        // the part's singable range (UX §A.2.4).
        XCTAssertEqual(model.displayedMidi(for: model.notes[0]), 76)
    }

    // MARK: - Mock fixture (the J-301 stand-in for P-305)

    func testDemoFixtureExercisesUnisonAbsenceAndBands() {
        let tracks = MockNoteTracks.demoTracks()
        let model = PianoRollModel(tracks: tracks, duration_s: MockNoteTracks.demoDuration_s)
        XCTAssertEqual(model.parts.count, 5)
        XCTAssertFalse(model.isPresent(part: .t2, phraseIndex: 1), "T2 is silent in phrase 1")
        XCTAssertFalse(model.isPresent(part: .bass, phraseIndex: 4), "the bass drops out in phrase 4")
        XCTAssertTrue(model.notes.contains(where: { $0.isUnison && $0.phraseIndex == 2 }),
                      "phrase 2 is the unison passage")
        XCTAssertTrue(model.notes.contains(where: { $0.band == .confirmed }))
        XCTAssertTrue(model.notes.contains(where: { $0.band == .provisional }))
        XCTAssertTrue(model.notes.contains(where: { $0.band == .unassigned }))
    }

    func testLongSongFixtureIsFourMinutesAndCulls() {
        let tracks = MockNoteTracks.longSongTracks()
        let model = PianoRollModel(tracks: tracks, duration_s: MockNoteTracks.longSongDuration_s)
        XCTAssertEqual(model.duration_s, 240, accuracy: 1e-9)
        XCTAssertGreaterThan(model.notes.count, 1000)
        XCTAssertLessThan(model.notes(inTimeRange: 0...10).count, 100,
                          "the canvas draws the visible window only")
    }

    func testAccessibilityDescriptionCarriesTheHonestFacts() {
        let tracks = MockNoteTracks.demoTracks()
        let model = PianoRollModel(tracks: tracks, duration_s: MockNoteTracks.demoDuration_s)
        let unisonNote = model.notes.first(where: \.isUnison)!
        let text = model.accessibilityDescription(for: unisonNote)
        XCTAssertTrue(text.contains(unisonNote.part.displayName))
        XCTAssertTrue(text.contains("confidence"))
        XCTAssertTrue(text.contains("unison"))
    }
}
