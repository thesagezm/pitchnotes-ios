import XCTest
import EngineCore
@testable import PitchLogic

// J-303 UltraStar `.txt` codec tests — the C-4 semantics, exercised against
// the frozen contract:
//
//   · note token pitch = MIDI − 60 (UltraStar 0 = C4 = MIDI 60), integer;
//   · note start/length are BEATS; start_s = GAP/1000 + beat * 60/BPM;
//   · round-trip is "lossless within schema": midi/start_s/end_s preserved
//     exactly (subject to BPM/GAP quantization); cents_ref → 0 and
//     confidence → 1.0 on import;
//   · the importer accepts the standard kinds `F : * R G`; export emits `:`
//     and `*` only.
//
// The format is reimplemented BY HAND from C-4 — no copyleft implementation
// is vendored, linked, or transcribed (AGENTS §9).

final class UltraStarCodecTests: XCTestCase {

    private func note(_ start: Double, _ end: Double, _ midi: Int,
                      cents: Int = 0, confidence: Double = 0.9) -> Note {
        Note(start_s: start, end_s: end, midi: midi, cents_ref: cents, confidence: confidence)
    }

    private func track(_ part: Part, _ notes: [Note]) -> NoteTrack {
        NoteTrack(part: part, notes: notes)
    }

    // MARK: - Export shape

    func testExportWritesBPMGapAndNoteLines() throws {
        let t = track(.bass, [note(0.0, 0.5, 48), note(0.5, 1.0, 50)])
        let result = try UltraStarCodec.export(track: t, bpm: 120, gap_ms: 0,
                                                title: "Test Song", artist: "PitchNotes")

        XCTAssertTrue(result.text.contains("#TITLE:Test Song"))
        XCTAssertTrue(result.text.contains("#ARTIST:PitchNotes"))
        XCTAssertTrue(result.text.contains("#BPM:120"))
        XCTAssertTrue(result.text.contains("#GAP:0"))
        // C-4: the pitch token is MIDI − 60 ⇒ MIDI 48 → −12, MIDI 50 → −10.
        XCTAssertTrue(result.text.contains(": 0 1 -12"), result.text)
        XCTAssertTrue(result.text.contains(": 1 1 -10"), result.text)
    }

    func testExportEmitsOnlyNormalAndGoldenKinds() throws {
        let t = track(.t1, [note(0.0, 0.5, 60), note(0.5, 1.0, 62)])
        let result = try UltraStarCodec.export(track: t, goldenNoteIndices: [1])

        let kinds = result.text.split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
            .compactMap { $0.first }
            .map { String($0) }
        XCTAssertEqual(Set(kinds), [":", "*"])
        // The golden marker is opt-in and positional (C-2.3 has no golden flag).
        XCTAssertTrue(result.text.contains(": 0 1 0"), result.text)
        XCTAssertTrue(result.text.contains("* 1 1 2"), result.text)
    }

    func testExportRefusesANonPositiveTempo() {
        XCTAssertThrowsError(try UltraStarCodec.export(track: track(.bass, []), bpm: 0)) { error in
            XCTAssertEqual(error as? UltraStarCodecError, UltraStarCodecError.nonPositiveBPM(0))
        }
    }

    func testExportQuantizesToTheBeatGridAndReportsTheError() throws {
        // 120 BPM ⇒ one beat = 0.5 s. A note at 0.3 s lands on beat 1 (0.5 s).
        let t = track(.bass, [note(0.3, 0.9, 48)])
        let result = try UltraStarCodec.export(track: t, bpm: 120)

        XCTAssertTrue(result.text.contains(": 1 1 -12"), result.text)
        XCTAssertEqual(result.maxTimingError_s, 0.2, accuracy: 1e-9)
    }

    // MARK: - Import

    func testImportReadsPitchTimingAndHeaders() throws {
        let text = """
        #TITLE:Round Trip
        #ARTIST:Someone
        #BPM:120
        #GAP:500
        : 0 2 0
        * 2 1 12
        """
        let result = try UltraStarCodec.parse(text: text, part: .bass)

        XCTAssertEqual(result.bpm, 120)
        XCTAssertEqual(result.gap_ms, 500)
        XCTAssertEqual(result.title, "Round Trip")
        XCTAssertEqual(result.artist, "Someone")
        XCTAssertEqual(result.track.part, .bass)
        XCTAssertEqual(result.track.notes.count, 2)

        // start_s = GAP/1000 + beat * 60/BPM.
        XCTAssertEqual(result.track.notes[0].start_s, 0.5, accuracy: 1e-9)
        XCTAssertEqual(result.track.notes[0].end_s, 1.5, accuracy: 1e-9)
        XCTAssertEqual(result.track.notes[0].midi, 60)   // pitch 0 ⇒ MIDI 60
        XCTAssertEqual(result.track.notes[1].start_s, 1.5, accuracy: 1e-9)
        XCTAssertEqual(result.track.notes[1].end_s, 2.0, accuracy: 1e-9)
        XCTAssertEqual(result.track.notes[1].midi, 72)   // pitch 12 ⇒ MIDI 72
        XCTAssertEqual(result.goldenNoteCount, 1)
    }

    func testImportResetsCentsAndConfidencePerContract() throws {
        let text = "#BPM:120\n: 0 1 0\n"
        let result = try UltraStarCodec.parse(text: text, part: .t1)

        XCTAssertEqual(result.track.notes[0].cents_ref, 0)
        XCTAssertEqual(result.track.notes[0].confidence, 1.0, accuracy: 1e-9)
    }

    func testImportAcceptsAllFiveStandardKindsAndCountsTheUnpitchedOnes() throws {
        let text = """
        #BPM:120
        : 0 1 0
        * 1 1 2
        F 2 1 4
        R 3 1 5
        G 4 1 7
        """
        let result = try UltraStarCodec.parse(text: text, part: .t2)

        // Only the two pitched kinds become notes.
        XCTAssertEqual(result.track.notes.count, 2)
        XCTAssertEqual(result.ignoredKindCounts[.freestyle], 1)
        XCTAssertEqual(result.ignoredKindCounts[.rap], 1)
        XCTAssertEqual(result.ignoredKindCounts[.g], 1)
        XCTAssertEqual(result.goldenNoteCount, 1)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testImportRequiresABPM() {
        XCTAssertThrowsError(try UltraStarCodec.parse(text: ": 0 1 0\n", part: .bass)) { error in
            XCTAssertEqual(error as? UltraStarCodecError, UltraStarCodecError.missingBPM)
        }
    }

    func testImportRejectsAnInvalidBPM() {
        XCTAssertThrowsError(try UltraStarCodec.parse(text: "#BPM:fast\n: 0 1 0\n", part: .bass)) { error in
            XCTAssertEqual(error as? UltraStarCodecError, UltraStarCodecError.invalidBPM("fast"))
        }
        XCTAssertThrowsError(try UltraStarCodec.parse(text: "#BPM:0\n: 0 1 0\n", part: .bass)) { error in
            XCTAssertEqual(error as? UltraStarCodecError, UltraStarCodecError.nonPositiveBPM(0))
        }
    }

    func testImportRejectsAnEmptyFile() {
        XCTAssertThrowsError(try UltraStarCodec.parse(text: "   \n  ", part: .bass)) { error in
            XCTAssertEqual(error as? UltraStarCodecError, UltraStarCodecError.emptyFile)
        }
    }

    func testStrictImportThrowsOnAMalformedLine() {
        let text = "#BPM:120\n: 0 1\n"
        XCTAssertThrowsError(try UltraStarCodec.parse(text: text, part: .bass, strict: true)) { error in
            XCTAssertEqual(error as? UltraStarCodecError, UltraStarCodecError.malformedNoteLine(": 0 1"))
        }
        // The lenient path skips it and says so.
        let lenient = try? UltraStarCodec.parse(text: text, part: .bass)
        XCTAssertEqual(lenient?.droppedNoteCount, 1)
        XCTAssertFalse(lenient?.warnings.isEmpty ?? true)
    }

    func testImportReportsDroppedLyrics() throws {
        let text = "#BPM:120\n: 0 1 0 hello\n"
        let result = try UltraStarCodec.parse(text: text, part: .bass)
        XCTAssertEqual(result.droppedLyricNoteCount, 1)
        XCTAssertEqual(result.track.notes.count, 1)
    }

    func testImportRepairsOverlapsToSatisfyV8() throws {
        // Two overlapping notes: 0.0–1.0 and 0.5–1.5.
        let text = "#BPM:120\n: 0 2 0\n: 1 2 2\n"
        let result = try UltraStarCodec.parse(text: text, part: .bass)

        XCTAssertEqual(result.repairedOverlapCount, 1)
        XCTAssertEqual(result.track.notes.count, 2)
        // The first note was trimmed to the second note's start.
        XCTAssertEqual(result.track.notes[0].start_s, 0.0, accuracy: 1e-9)
        XCTAssertEqual(result.track.notes[0].end_s, 0.5, accuracy: 1e-9)
        XCTAssertEqual(result.track.notes[1].start_s, 0.5, accuracy: 1e-9)
        XCTAssertEqual(result.track.notes[1].end_s, 1.5, accuracy: 1e-9)
    }

    func testImportDropsAZeroLengthNote() throws {
        let text = "#BPM:120\n: 0 0 0\n: 1 1 2\n"
        let result = try UltraStarCodec.parse(text: text, part: .bass)
        XCTAssertEqual(result.droppedNoteCount, 1)
        XCTAssertEqual(result.track.notes.count, 1)
    }

    func testImportClampsAPitchOutsideTheContractRange() throws {
        // UltraStar pitch 120 ⇒ MIDI 180, far outside V9's 24…96.
        let text = "#BPM:120\n: 0 1 120\n"
        let result = try UltraStarCodec.parse(text: text, part: .bass)
        XCTAssertEqual(result.track.notes[0].midi, 96)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testImportToleratesCommentsAndUnknownHeaders() throws {
        let text = """
        // a comment line
        #BPM:120
        #MP3:song.ogg
        #YEAR:1999
        : 0 1 0
        """
        let result = try UltraStarCodec.parse(text: text, part: .bass)
        XCTAssertEqual(result.track.notes.count, 1)
        XCTAssertEqual(result.bpm, 120)
    }

    // MARK: - The round-trip (C-4's "lossless within schema")

    func testRoundTripIsLosslessOnTheBeatGrid() throws {
        let original = track(.bass, [
            note(0.0, 0.5, 48),
            note(0.5, 1.5, 50, cents: 7, confidence: 0.4),
            note(2.0, 2.5, 43),
        ])
        let exported = try UltraStarCodec.export(track: original, bpm: 120)
        let imported = try UltraStarCodec.parse(text: exported.text, part: .bass)

        XCTAssertEqual(imported.track.notes.count, original.notes.count)
        for (before, after) in zip(original.notes, imported.track.notes) {
            XCTAssertEqual(after.midi, before.midi)
            XCTAssertEqual(after.start_s, before.start_s, accuracy: 1e-9)
            XCTAssertEqual(after.end_s, before.end_s, accuracy: 1e-9)
            // The format cannot carry these (C-4) — they reset.
            XCTAssertEqual(after.cents_ref, 0)
            XCTAssertEqual(after.confidence, 1.0, accuracy: 1e-9)
        }
        XCTAssertEqual(exported.maxTimingError_s, 0, accuracy: 1e-9)
    }

    func testRoundTripRespectsTheGap() throws {
        let original = track(.t1, [note(0.5, 1.0, 60)])
        let exported = try UltraStarCodec.export(track: original, bpm: 120, gap_ms: 1000)
        let imported = try UltraStarCodec.parse(text: exported.text, part: .t1)

        // gap 1000 ms ⇒ beat 0 is at 1.0 s; the note at 0.5 s is before the
        // gap and is moved to beat 0 (reported, never silent).
        XCTAssertFalse(exported.warnings.isEmpty)
        XCTAssertEqual(imported.track.notes.first?.start_s ?? -1, 1.0, accuracy: 1e-9)
    }

    func testRoundTripOfTheMockTracksKeepsPitchAndStaysWithinHalfABeat() throws {
        // The mock tracks are NOT on a 120 BPM grid — that is the honest case
        // C-4 covers with "subject to BPM/GAP quantization": the pitch is
        // exact, the timing moves by at most half a beat.
        let mocks = MockNoteTracks.demoTracks()
        let halfBeat = 60.0 / UltraStarCodec.defaultBPM / 2.0

        for part in MockNoteTracks.maleParts {
            guard let original = mocks[part] else {
                XCTFail("missing mock track for \(part)")
                continue
            }
            let exported = try UltraStarCodec.export(track: original)
            let imported = try UltraStarCodec.parse(text: exported.text, part: part)

            XCTAssertEqual(imported.track.notes.count, original.notes.count,
                           "note count changed for \(part)")
            for (before, after) in zip(original.notes, imported.track.notes) {
                XCTAssertEqual(after.midi, before.midi, "pitch changed for \(part)")
                XCTAssertLessThanOrEqual(abs(after.start_s - before.start_s), halfBeat + 1e-9)
                XCTAssertLessThanOrEqual(abs(after.end_s - before.end_s), halfBeat + 1e-9)
            }
            XCTAssertLessThanOrEqual(exported.maxTimingError_s, halfBeat + 1e-9)
        }
    }

    func testEveryExportedLineIsAParseableNoteLine() throws {
        let t = track(.baritenor, [note(0.0, 0.5, 55), note(0.5, 1.0, 57)])
        let exported = try UltraStarCodec.export(track: t)
        let imported = try UltraStarCodec.parse(text: exported.text, part: .baritenor, strict: true)
        XCTAssertEqual(imported.track.notes.count, 2)
        XCTAssertEqual(imported.droppedNoteCount, 0)
        XCTAssertEqual(imported.repairedOverlapCount, 0)
    }
}
