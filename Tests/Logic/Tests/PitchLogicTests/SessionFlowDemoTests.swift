import XCTest
import EngineCore
@testable import PitchLogic

// J-402 · The demo path's pure pieces: DemoSinger (the SYNTHETIC performer —
// labelled, never a real engine's credit) and the in-session phrase-span
// lookup behind [Restart phrase].

final class DemoSingerTests: XCTestCase {

    /// A two-note reference: 1.0–3.0 s on midi 60, 4.0–5.0 s on midi 67.
    private func reference() -> NoteTrack {
        NoteTrack(part: .bass, notes: [
            Note(start_s: 1.0, end_s: 3.0, midi: 60, cents_ref: 0, confidence: 0.9,
                 assignmentBand: nil),
            Note(start_s: 4.0, end_s: 5.0, midi: 67, cents_ref: 0, confidence: 0.9,
                 assignmentBand: nil),
        ])
    }

    func testFramesAreOnTheHopGridAndSessionLocal() {
        let env = SessionEnvironment()
        let frames = DemoSinger.frames(for: reference(), environment: env,
                                       countIn_s: 2.0, sessionEnd_s: 8.0)
        XCTAssertFalse(frames.isEmpty)
        XCTAssertEqual(frames.first?.t, 0)
        for (a, b) in zip(frames, frames.dropFirst()) {
            XCTAssertEqual(b.t - a.t, SessionGrader.hop_s, accuracy: 1e-9)
        }
        XCTAssertLessThan(frames.last!.t, 8.0)
    }

    func testVoicedExactlyOnTheCountInShiftedSpans() {
        let frames = DemoSinger.frames(for: reference(), environment: SessionEnvironment(),
                                       countIn_s: 2.0, sessionEnd_s: 8.0)
        // A frame at session t 3.5 is reference t 1.5 — inside note 0.
        let mid = frames.first { $0.t >= 3.5 && $0.t < 3.5 + SessionGrader.hop_s }
        XCTAssertEqual(mid?.hz ?? 0, PitchMath.hz(forMidi: 60), accuracy: 0.01)
        XCTAssertEqual(mid?.loudness_db, DemoSinger.voicedLoudness_db)

        // A frame at session t 1.0 is reference t −1.0 — before the reference.
        let early = frames.first { $0.t >= 1.0 && $0.t < 1.0 + SessionGrader.hop_s }
        XCTAssertEqual(early?.hz, 0)

        // Session t 5.5 = reference t 3.5 — the gap between the notes.
        let gap = frames.first { $0.t >= 5.5 && $0.t < 5.5 + SessionGrader.hop_s }
        XCTAssertEqual(gap?.hz, 0)
    }

    func testTheC20TransformAppliesToTheRenderedPitch() {
        // +2 semitones ⇒ the rendered pitch is midi 62's (C-20 §1/§3 —
        // tuningCents 0 preserved; the SHIFT moves midi, nothing else).
        var env = SessionEnvironment()
        env.transpositionSemitones = 2
        let frames = DemoSinger.frames(for: reference(), environment: env,
                                       countIn_s: 0, sessionEnd_s: 4.0)
        let mid = frames.first { $0.hz > 0 }
        XCTAssertEqual(mid?.hz ?? 0, PitchMath.hz(forMidi: 62), accuracy: 0.01)
    }

    func testEveryRenderedFrameIsTaggedDemoSynthAndNeverARealEngine() {
        let frames = DemoSinger.frames(for: reference(), environment: SessionEnvironment(),
                                       countIn_s: 0, sessionEnd_s: 2.0)
        XCTAssertTrue(frames.allSatisfy { $0.engine_id == DemoSinger.engineID })
        // THE HONESTY PIN: the tag is NOT one of C-2.4's engine identities —
        // no real engine may ever be credited with a synthetic stream.
        XCTAssertNil(PitchEngineID(rawValue: DemoSinger.engineID))
    }

    func testUnvoicedFramesCarrySilenceAndNoConfidence() {
        let frames = DemoSinger.frames(for: reference(), environment: SessionEnvironment(),
                                       countIn_s: 0, sessionEnd_s: 1.0)
        // Note 0 starts at 1.0 — the whole 0–1 s stream is unvoiced.
        XCTAssertTrue(frames.allSatisfy { $0.hz == 0 && $0.confidence == 0
                                       && $0.loudness_db == -120 })
    }

    func testMarkersFromTheDemoStreamAreHits() {
        // The integration: the demo stream through the real marker math.
        let ref = reference()
        let env = SessionEnvironment()
        let frames = DemoSinger.frames(for: ref, environment: env,
                                       countIn_s: 0, sessionEnd_s: 6.0)
        for note in ref.notes {
            let inSpan = frames.filter {
                $0.t >= note.start_s - 1e-9 && $0.t < note.end_s - 1e-9
            }
            let marker = SessionFeedback.marker(for: note, frames: inSpan,
                                                environment: env,
                                                config: GradingConfig())
            if case .hit = marker {} else {
                XCTFail("a PERFECT synthetic singer must hit note \(note.midi): got \(marker)")
            }
        }
    }

    func testSessionEndCoversLastNotePlusTail() {
        let end = DemoSinger.sessionEnd_s(for: reference(),
                                          environment: SessionEnvironment(),
                                          countIn_s: 2.0, tail_s: 1.0)
        XCTAssertEqual(end, 2.0 + 5.0 + 1.0, accuracy: 1e-9)
    }

    func testTheRendererIsDeterministic() {
        let a = DemoSinger.frames(for: reference(), environment: SessionEnvironment(),
                                  countIn_s: 1.0, sessionEnd_s: 6.0)
        let b = DemoSinger.frames(for: reference(), environment: SessionEnvironment(),
                                  countIn_s: 1.0, sessionEnd_s: 6.0)
        XCTAssertEqual(a.count, b.count)
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x.t, y.t, accuracy: 1e-12)
            XCTAssertEqual(x.hz, y.hz, accuracy: 1e-12)
            XCTAssertEqual(x.loudness_db, y.loudness_db)
        }
    }
}

final class PhraseSpanTests: XCTestCase {

    /// Phrases: [0–1, 1.2–2.2] (0.2 s gap — one phrase), then [5–6] (a
    /// 2.8 s gap — another phrase). derivedPhraseGap_s = 1.0.
    private func reference() -> NoteTrack {
        NoteTrack(part: .bass, notes: [
            Note(start_s: 0.0, end_s: 1.0, midi: 60, cents_ref: 0, confidence: 0.9,
                 assignmentBand: nil),
            Note(start_s: 1.2, end_s: 2.2, midi: 62, cents_ref: 0, confidence: 0.9,
                 assignmentBand: nil),
            Note(start_s: 5.0, end_s: 6.0, midi: 64, cents_ref: 0, confidence: 0.9,
                 assignmentBand: nil),
        ])
    }

    func testAMidPhraseTimeResolvesToTheWholePhraseSpan() {
        let span = SessionFeedback.phraseSpan(containing: 1.5, reference: reference(),
                                              environment: SessionEnvironment())
        XCTAssertEqual(span?.start ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(span?.end ?? -1, 2.2, accuracy: 1e-9)
    }

    func testTheSecondPhraseSpansOnlyItself() {
        let span = SessionFeedback.phraseSpan(containing: 5.5, reference: reference(),
                                              environment: SessionEnvironment())
        XCTAssertEqual(span?.start ?? -1, 5.0, accuracy: 1e-9)
        XCTAssertEqual(span?.end ?? -1, 6.0, accuracy: 1e-9)
    }

    func testNilInTheGapBetweenPhrases() {
        XCTAssertNil(SessionFeedback.phraseSpan(containing: 3.5, reference: reference(),
                                                environment: SessionEnvironment()))
    }

    func testNilBeforeTheFirstNoteAndAfterTheLast() {
        XCTAssertNil(SessionFeedback.phraseSpan(containing: -0.5, reference: reference(),
                                                environment: SessionEnvironment()))
        XCTAssertNil(SessionFeedback.phraseSpan(containing: 7.0, reference: reference(),
                                                environment: SessionEnvironment()))
    }

    func testTheTempoTransformMovesTheSpan() {
        // tempoScale 2 renders 0–1 s as 0–0.5 s (C-20 §1) — the restart
        // rewinds to the RENDERED time the user actually hears. The transform
        // also compresses the 0.2 s gap to 0.1 s, which is BELOW the derived
        // phrase gap ⇒ the two notes merge into ONE rendered phrase ending
        // at 1.1 — the derived rule operates on TRANSFORMED times, pinned.
        var env = SessionEnvironment()
        env.tempoScale = 2.0
        let span = SessionFeedback.phraseSpan(containing: 0.4, reference: reference(),
                                              environment: env)
        XCTAssertEqual(span?.start ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(span?.end ?? -1, 1.1, accuracy: 1e-9)
    }
}
