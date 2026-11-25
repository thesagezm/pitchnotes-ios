import XCTest
@testable import EngineCore

// P-305 · NoteTrack v1.1 metadata (C-10.0 / C-10.1 / C-10.2, D-41).
//
// The two halves of this suite are the two halves of the contract:
//   1. the v1.1 metadata is COMPUTED correctly (the bands, the presence, the
//      unison rule), and
//   2. the ABSENCE RULE holds — a v0.0 note file behaves exactly as it did
//      before v1.1 and stays valid forever.

final class NoteTrackV11Tests: XCTestCase {

    // MARK: - The bands (D-41 §1)

    func testBandThresholdsAreD41sNumbers() {
        XCTAssertEqual(AssignmentBand.band(forConfidence: 0.80), .confirmed)
        XCTAssertEqual(AssignmentBand.band(forConfidence: 1.00), .confirmed)
        XCTAssertEqual(AssignmentBand.band(forConfidence: 0.7999), .provisional)
        XCTAssertEqual(AssignmentBand.band(forConfidence: 0.50), .provisional)
        XCTAssertEqual(AssignmentBand.band(forConfidence: 0.4999), .unassigned)
        XCTAssertEqual(AssignmentBand.band(forConfidence: 0.0), .unassigned)
    }

    func testBandRawValuesAreTheContractSpellings() {
        XCTAssertEqual(AssignmentBand.confirmed.rawValue, "CONFIRMED")
        XCTAssertEqual(AssignmentBand.provisional.rawValue, "PROVISIONAL")
        XCTAssertEqual(AssignmentBand.unassigned.rawValue, "UNASSIGNED")
        XCTAssertEqual(AssignmentBand.allCases.count, 3)
    }

    // MARK: - The writer

    func testWriterProducesTheV11File() {
        let notes = [
            AssignedNote(start_s: 0.0, end_s: 1.0, midi: 48, confidence: 0.95, salience: 0.62),
            AssignedNote(start_s: 1.0, end_s: 2.0, midi: 52, confidence: 0.60),
            AssignedNote(start_s: 2.0, end_s: 3.0, midi: 55, confidence: 0.20)
        ]
        let track = NoteTrackV11Builder.build(part: .bass,
                                             notes: notes,
                                             spans: PhraseSpan.fixedGrid(duration: 4.0),
                                             engineVersion: "basicpitch-vendored-2")
        XCTAssertEqual(track.contractVersion, "v1.1")
        XCTAssertEqual(track.part, .bass)
        XCTAssertEqual(track.engineVersion, "basicpitch-vendored-2")
        XCTAssertEqual(track.notes.map { $0.assignmentBand },
                       ["CONFIRMED", "PROVISIONAL", "UNASSIGNED"])
        XCTAssertEqual(track.notes.map { $0.salience }, [0.62, nil, nil])
        XCTAssertEqual(track.assignmentSummary,
                       AssignmentSummary(confirmed: 1, provisional: 1, unassigned: 1))
        XCTAssertTrue(BundleValidator.validate(noteTrack: track).isValid)
    }

    func testWriterSortsNotesAndKeepsTheUnisonFlagWithItsNote() {
        // The unison flags travel WITH their notes: a flag can never drift
        // onto another note when the notes are sorted.
        let notes = [
            AssignedNote(start_s: 2.0, end_s: 3.0, midi: 55, confidence: 0.9),
            AssignedNote(start_s: 0.0, end_s: 1.0, midi: 48, confidence: 0.9)
        ]
        let track = NoteTrackV11Builder.build(part: .bass,
                                             notes: notes,
                                             spans: PhraseSpan.fixedGrid(duration: 4.0),
                                             engineVersion: "e",
                                             unison: [false, true])
        XCTAssertEqual(track.notes.map { $0.start_s }, [0.0, 2.0])
        XCTAssertEqual(track.notes.map { $0.unison ?? false }, [true, false])
    }

    // MARK: - The presence (D-41 §2)

    func testPhraseGridIsFourSecondSpans() {
        let spans = PhraseSpan.fixedGrid(duration: 9.5)
        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans[0], PhraseSpan(index: 0, start_s: 0.0, end_s: 4.0))
        XCTAssertEqual(spans[1], PhraseSpan(index: 1, start_s: 4.0, end_s: 8.0))
        XCTAssertEqual(spans[2], PhraseSpan(index: 2, start_s: 8.0, end_s: 9.5))
        XCTAssertTrue(PhraseSpan.fixedGrid(duration: 0).isEmpty)
    }

    func testPresenceNeedsANoteAndAMeanConfidenceOfAtLeast060() {
        let spans = PhraseSpan.fixedGrid(duration: 8.0)
        // Phrase 0: one confident note ⇒ present. Phrase 1: one note below the
        // bar ⇒ absent (but the entry is NOT an error). Phrase 2: no note at
        // all ⇒ absent.
        let notes = [
            AssignedNote(start_s: 0.0, end_s: 1.0, midi: 48, confidence: 0.90),
            AssignedNote(start_s: 4.0, end_s: 5.0, midi: 48, confidence: 0.59)
        ]
        let presence = NoteTrackV11Builder.computePresence(notes: notes, spans: spans)
        XCTAssertEqual(presence.count, 2)
        XCTAssertTrue(presence[0].present)
        XCTAssertEqual(presence[0].noteCount, 1)
        XCTAssertEqual(presence[0].meanConfidence, 0.90, accuracy: 1e-9)
        XCTAssertFalse(presence[1].present)
        XCTAssertEqual(presence[1].noteCount, 1)
        XCTAssertEqual(presence[1].meanConfidence, 0.59, accuracy: 1e-9)
    }

    func testPresenceMeanIsOverTheNotesInThePhrase() {
        let spans = PhraseSpan.fixedGrid(duration: 4.0)
        let notes = [
            AssignedNote(start_s: 0.0, end_s: 1.0, midi: 48, confidence: 1.0),
            AssignedNote(start_s: 1.0, end_s: 2.0, midi: 50, confidence: 0.2)
        ]
        let presence = NoteTrackV11Builder.computePresence(notes: notes, spans: spans)
        XCTAssertEqual(presence[0].noteCount, 2)
        XCTAssertEqual(presence[0].meanConfidence, 0.6, accuracy: 1e-9)
        // 0.60 is exactly the bar ⇒ present.
        XCTAssertTrue(presence[0].present)
    }

    func testANoteIsCountedInThePhraseItStartsIn() {
        let spans = PhraseSpan.fixedGrid(duration: 8.0)
        let notes = [AssignedNote(start_s: 3.9, end_s: 4.5, midi: 48, confidence: 0.9)]
        let presence = NoteTrackV11Builder.computePresence(notes: notes, spans: spans)
        XCTAssertEqual(presence[0].noteCount, 1)
        XCTAssertEqual(presence[1].noteCount, 0)
    }

    // MARK: - The unison rule (D-41 §3)

    func testUnisonAcrossPartsWithinTheSamePhrase() {
        let spans = PhraseSpan.fixedGrid(duration: 8.0)
        let bass = [AssignedNote(start_s: 0.0, end_s: 2.0, midi: 48, confidence: 0.9)]
        let t2 = [AssignedNote(start_s: 0.5, end_s: 2.5, midi: 48, confidence: 0.9)]
        let flags = NoteTrackV11Builder.computeUnisonFlags(notes: bass,
                                                          spans: spans,
                                                          otherParts: [.t2: t2])
        XCTAssertEqual(flags, [true])
    }

    func testUnisonNeedsTheSamePhraseTheSameMidiAndWithin25Cents() {
        let spans = PhraseSpan.fixedGrid(duration: 8.0)
        let bass = [AssignedNote(start_s: 0.0, end_s: 2.0, midi: 48, cents_ref: 0, confidence: 0.9)]
        // (a) a different phrase ⇒ not a unison.
        let otherPhrase = [AssignedNote(start_s: 4.0, end_s: 6.0, midi: 48, cents_ref: 0, confidence: 0.9)]
        XCTAssertEqual(NoteTrackV11Builder.computeUnisonFlags(notes: bass, spans: spans,
                                                              otherParts: [.t2: otherPhrase]), [false])
        // (b) a different MIDI ⇒ not a unison.
        let otherPitch = [AssignedNote(start_s: 0.0, end_s: 2.0, midi: 49, cents_ref: 0, confidence: 0.9)]
        XCTAssertEqual(NoteTrackV11Builder.computeUnisonFlags(notes: bass, spans: spans,
                                                              otherParts: [.t2: otherPitch]), [false])
        // (c) 25 cents away ⇒ a unison (the rule is "within ±25 cents").
        let withinTolerance = [AssignedNote(start_s: 0.0, end_s: 2.0, midi: 48, cents_ref: 25, confidence: 0.9)]
        XCTAssertEqual(NoteTrackV11Builder.computeUnisonFlags(notes: bass, spans: spans,
                                                              otherParts: [.t2: withinTolerance]), [true])
        // (d) 26 cents away ⇒ not a unison.
        let outsideTolerance = [AssignedNote(start_s: 0.0, end_s: 2.0, midi: 48, cents_ref: 26, confidence: 0.9)]
        XCTAssertEqual(NoteTrackV11Builder.computeUnisonFlags(notes: bass, spans: spans,
                                                              otherParts: [.t2: outsideTolerance]), [false])
    }

    func testBuildTracksMarksBothSidesOfAUnison() {
        let parts: [Part: [AssignedNote]] = [
            .bass: [AssignedNote(start_s: 0.0, end_s: 2.0, midi: 48, confidence: 0.9)],
            .t1: [AssignedNote(start_s: 0.0, end_s: 2.0, midi: 48, confidence: 0.9)]
        ]
        let tracks = NoteTrackV11Builder.buildTracks(parts: parts,
                                                     spans: PhraseSpan.fixedGrid(duration: 4.0),
                                                     engineVersion: "e")
        XCTAssertEqual(tracks[.bass]?.notes.first?.unison, true)
        XCTAssertEqual(tracks[.t1]?.notes.first?.unison, true)
    }

    // MARK: - The absence rule (C-10.0) — the binding part

    func testAV00NoteFileHasNoneOfTheNewFieldsAndStaysValid() {
        let json = """
        {"contractVersion":"v0.0","part":"BASS","notes":[{"start_s":0.0,"end_s":1.0,"midi":48,"cents_ref":0,"confidence":0.5}]}
        """
        let track = try! JSONDecoder().decode(NoteTrack.self, from: Data(json.utf8))
        XCTAssertNil(track.engineVersion)
        XCTAssertNil(track.partPresence)
        XCTAssertNil(track.assignmentSummary)
        XCTAssertNil(track.notes[0].unison)
        XCTAssertNil(track.notes[0].salience)
        XCTAssertNil(track.notes[0].assignmentBand)
        XCTAssertTrue(BundleValidator.validate(noteTrack: track).isValid)
    }

    func testTheV00WireFormatIsUnchanged() {
        let track = NoteTrack(part: .bass,
                              notes: [Note(start_s: 0.0, end_s: 1.0, midi: 48, confidence: 0.5)])
        let data = try! JSONEncoder().encode(track)
        let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(Set(object.keys), ["contractVersion", "part", "notes"])
        let notes = object["notes"] as! [[String: Any]]
        XCTAssertEqual(Set(notes[0].keys), ["start_s", "end_s", "midi", "cents_ref", "confidence"])
    }

    func testTheConsumerDerivesWhatTheFileOmits() {
        let note = Note(start_s: 0.0, end_s: 1.0, midi: 48, confidence: 0.85)
        XCTAssertEqual(NoteTrackMetadata.band(for: note), .confirmed)
        XCTAssertFalse(NoteTrackMetadata.isUnison(note))
        let track = NoteTrack(part: .bass, notes: [note])
        XCTAssertEqual(NoteTrackMetadata.engineVersion(for: track), "unknown")
        XCTAssertEqual(NoteTrackMetadata.summary(for: track),
                       AssignmentSummary(confirmed: 1, provisional: 0, unassigned: 0))
        XCTAssertNil(NoteTrackMetadata.presence(for: track, phraseIndex: 0))
    }

    func testTheBandPresentInTheFileWinsOverTheDerivedOne() {
        let note = Note(start_s: 0.0, end_s: 1.0, midi: 48, confidence: 0.85, assignmentBand: "PROVISIONAL")
        XCTAssertEqual(NoteTrackMetadata.band(for: note), .provisional)
    }

    func testAnInvalidBandStringFallsBackToTheDerivedBand() {
        // The invalid spelling is a V16 VIOLATION that the validator reports;
        // the consumer must not crash on it and must not pretend it meant
        // anything.
        let note = Note(start_s: 0.0, end_s: 1.0, midi: 48, confidence: 0.85, assignmentBand: "PROB")
        XCTAssertEqual(NoteTrackMetadata.band(for: note), .confirmed)
    }

    // MARK: - The validators (V16, V17, V18)

    func testV16FlagsAnOutOfRangeSalienceAndAnUnknownBandString() {
        var track = NoteTrackV11Builder.build(part: .bass,
                                              notes: [AssignedNote(start_s: 0.0, end_s: 1.0, midi: 48, confidence: 0.9, salience: 1.4)],
                                              spans: PhraseSpan.fixedGrid(duration: 4.0),
                                              engineVersion: "e")
        track.notes[0].assignmentBand = "CONFIRMEDISH"
        let result = BundleValidator.validate(noteTrack: track)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.violations.contains { $0.rule == "V16" })
    }

    func testV16DoesNotApplyToAV00File() {
        // The v0.0 file is validated under V7–V10 ONLY: an out-of-range
        // salience in a v0.0 file is NOT a v1.1 violation (the era gate is
        // what keeps the old file valid forever).
        var track = NoteTrack(part: .bass,
                              notes: [Note(start_s: 0.0, end_s: 1.0, midi: 48, confidence: 0.9)])
        track.notes[0].salience = 4.2
        track.notes[0].assignmentBand = "NONSENSE"
        XCTAssertTrue(BundleValidator.validate(noteTrack: track).isValid)
    }

    func testV17FlagsAnInconsistentPresenceEntry() {
        var track = NoteTrackV11Builder.build(part: .bass,
                                              notes: [AssignedNote(start_s: 0.0, end_s: 1.0, midi: 48, confidence: 0.9)],
                                              spans: PhraseSpan.fixedGrid(duration: 4.0),
                                              engineVersion: "e")
        track.partPresence?[0].present = false
        let result = BundleValidator.validate(noteTrack: track)
        XCTAssertTrue(result.violations.contains { $0.rule == "V17" })
    }

    func testV17FlagsANonAscendingPhraseIndex() {
        var track = NoteTrackV11Builder.build(part: .bass,
                                              notes: [],
                                              spans: PhraseSpan.fixedGrid(duration: 8.0),
                                              engineVersion: "e")
        track.partPresence?[0].phraseIndex = 5
        let result = BundleValidator.validate(noteTrack: track)
        XCTAssertTrue(result.violations.contains { $0.rule == "V17" })
    }

    func testV18FlagsABandThatDisagreesWithTheConfidence() {
        var track = NoteTrackV11Builder.build(part: .bass,
                                              notes: [AssignedNote(start_s: 0.0, end_s: 1.0, midi: 48, confidence: 0.95)],
                                              spans: PhraseSpan.fixedGrid(duration: 4.0),
                                              engineVersion: "e")
        track.notes[0].assignmentBand = "UNASSIGNED"
        let result = BundleValidator.validate(noteTrack: track)
        XCTAssertTrue(result.violations.contains { $0.rule == "V18" })
    }

    func testAnUnknownMajorIsRejected() {
        let track = NoteTrack(contractVersion: "v2.0", part: .bass,
                              notes: [Note(start_s: 0.0, end_s: 1.0, midi: 48, confidence: 0.9)])
        XCTAssertFalse(BundleValidator.validate(noteTrack: track).isValid)
    }

    func testTheV11FileRoundTrips() throws {
        let track = NoteTrackV11Builder.build(part: .t1,
                                              notes: [AssignedNote(start_s: 0.0, end_s: 1.0, midi: 67,
                                                                   confidence: 0.9, salience: 0.4)],
                                              spans: PhraseSpan.fixedGrid(duration: 4.0),
                                              engineVersion: "basicpitch-vendored-2")
        let data = try JSONEncoder().encode(track)
        let decoded = try JSONDecoder().decode(NoteTrack.self, from: data)
        XCTAssertEqual(decoded, track)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(Set(object.keys),
                       ["contractVersion", "part", "notes", "engineVersion", "partPresence", "assignmentSummary"])
    }
}
