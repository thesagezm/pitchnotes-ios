import XCTest
@testable import PlaybackKit
import EngineCore

// PlaybackKit smoke tests (P-402, PAUL lane — macOS CI only; the package is
// Apple-only, so Linux never builds it). NO engine start, NO audio device:
// these cover the platform-neutral surface — (1) the lane config's mapping
// from the C-20 environment (pitch cents / rate), (2) the two time mappings
// (bundle vs render) with their UNIT FACT, and (3) the transform identity —
// the engine and the grader construct their mappings from ONE
// PlaybackTransform built from ONE environment (D-33: one semantic, never
// two). The render-timeline measurements (the varispeed pitch fact, the loop
// seam, the drift budget) live in VarispeedRenderTests.

final class PlaybackKitSmokeTests: XCTestCase {

    // MARK: - (1) The lane config maps the C-20 environment

    func testLaneConfigMapsTheEnvironmentToTimePitchValues() throws {
        // KEY: pitch = whole semitones × 100 cents. NEVER tuningCents
        // (D-22/C-20 §3 — the audio is not retuned; the grading reference is).
        let env = try PlaybackEnvironment(transpositionSemitones: 2, tempoScale: 1.25)
        let config = PlaybackLaneConfig(sampleRate: 44_100, environment: env)
        XCTAssertEqual(config.pitchCents, 200.0)
        XCTAssertEqual(config.rate, 1.25)

        let withTuning = PlaybackLaneConfig(
            sampleRate: 44_100,
            environment: try PlaybackEnvironment(transpositionSemitones: 0))
        XCTAssertEqual(withTuning.pitchCents, 0.0,
                       "tuning_cents NEVER rides on the playback pitch (D-22)")
        XCTAssertEqual(withTuning.rate, 1.0)

        let down = PlaybackLaneConfig(
            sampleRate: 44_100,
            environment: try PlaybackEnvironment(transpositionSemitones: -12))
        XCTAssertEqual(down.pitchCents, -1200.0)
        XCTAssertEqual(down.rate, 1.0)
    }

    // MARK: - (2) The two time mappings and their unit fact

    func testBundleAndRenderTimeMappingsFollowTheUnitFact() throws {
        // playerTime.sampleTime counts the PLAYER's output frames — FILE
        // frames at the file rate. bundle = sampleTime / sr;
        // render = sampleTime / (sr × tempoScale).
        let config = PlaybackLaneConfig(
            sampleRate: 44_100,
            environment: try PlaybackEnvironment(tempoScale: 1.25))
        let lane = PlaybackLane(part: .bass,
                                file: try Self.silentFile(seconds: 2),
                                config: config)
        // 44 100 file frames in: exactly 1.0 s of SONG, 0.8 s of WALL.
        XCTAssertEqual(lane.bundleTime(sampleTime: 44_100), 1.0, accuracy: 1e-12)
        XCTAssertEqual(lane.renderTime(sampleTime: 44_100), 0.8, accuracy: 1e-12)
        // The identity: at tempoScale 1.0 the two coincide.
        let neutral = PlaybackLane(part: .bass,
                                   file: try Self.silentFile(seconds: 2),
                                   config: PlaybackLaneConfig(
                                        sampleRate: 44_100,
                                        environment: .neutral))
        XCTAssertEqual(neutral.bundleTime(sampleTime: 88_200), 2.0, accuracy: 1e-12)
        XCTAssertEqual(neutral.renderTime(sampleTime: 88_200), 2.0, accuracy: 1e-12)
    }

    // MARK: - (3) The transform identity (one semantic, never two)

    func testTheEngineExposesTheSameTransformTheGraderUses() throws {
        let env = try PlaybackEnvironment(transpositionSemitones: -3, tempoScale: 0.9)
        let engine = try ReferencePlaybackEngine(
            bundleStems: [.bass: Self.silentFileURL(seconds: 4)],
            environment: env)
        // THE D-33 PIN: the engine's transform is constructed from the SAME
        // environment value — the player and the grader cannot disagree.
        XCTAssertEqual(engine.transform, PlaybackTransform(environment: env))
        XCTAssertEqual(engine.transform.mapMidi(55), 52)
        XCTAssertEqual(engine.transform.mapTime(10.0), 10.0 / 0.9, accuracy: 1e-12)
        // And the lane config matches the same environment.
        let lane = try XCTUnwrap(engine.lane(for: .bass))
        XCTAssertEqual(lane.config.pitchCents, -300.0)
        XCTAssertEqual(lane.config.rate, 0.9)
        XCTAssertEqual(engine.parts, [.bass])
    }

    func testTheEngineRefusesABrokenBundle() throws {
        // No stems at all: refused with the honest error (nothing to play —
        // never a silent half-engine).
        XCTAssertThrowsError(try ReferencePlaybackEngine(bundleStems: [:],
                                                         environment: .neutral)) { error in
            XCTAssertEqual(error as? PlaybackKitError, .noStems)
        }
        // Mixed stem rates: a manifest lie — refused (C-2.1/D-8 consistency).
        XCTAssertThrowsError(try ReferencePlaybackEngine(
            bundleStems: [.bass: Self.silentFileURL(seconds: 1, rate: 44_100),
                          .t1: Self.silentFileURL(seconds: 1, rate: 48_000)],
            environment: .neutral)) { error in
            XCTAssertEqual(error as? PlaybackKitError, .mixedSampleRates(44_100, 48_000))
        }
    }

    // MARK: - helpers

    static func silentFile(seconds: Double, rate: Double = 44_100) throws -> AVAudioFile {
        try AVAudioFile(forReading: silentFileURL(seconds: seconds, rate: rate))
    }

    static func silentFileURL(seconds: Double, rate: Double = 44_100) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("playbackkit-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try! AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        // Silence (all zero) — the scheduling math does not care about the
        // content; the RENDER tests write their own sine files.
        try! file.write(from: buffer)
        return url
    }
}
