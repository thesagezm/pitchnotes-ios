import XCTest
import EngineCore
@testable import PitchLogic

// J-203 mixer logic tests: lane resolution (focus/mute/solo), the D-12
// never-hard-solo focus preset, 15 ms glide envelope, and transport loop math.

final class MixerModelTests: XCTestCase {

    private func mixer(parts: [Part] = [.t1, .instrumental],
                       focus: Part? = .t1) -> MixerModel {
        MixerModel(parts: parts, focusTarget: focus)
    }

    // MARK: - Lane construction (D-9)

    func testInstrumentalLaneAbsentWhenAcapella() {
        let lanes = MixerModel(parts: [.t1], focusTarget: nil).lanes
        XCTAssertEqual(lanes.map(\.part), [.t1],
                       "D-9: no INSTRUMENTAL lane when hasInstrumental == false")
    }

    func testTwoStemBundleYieldsTwoLanes() {
        let model = mixer()
        XCTAssertEqual(model.lanes.map(\.part), [.t1, .instrumental])
    }

    // MARK: - Focus preset (default, D-12)

    func testFocusPresetTargetUnityOthersMinus12() {
        let model = mixer(focus: .t1)
        XCTAssertEqual(model.resolvedGain(for: .t1), 1.0, accuracy: 1e-9)
        XCTAssertEqual(model.resolvedGain(for: .instrumental),
                       MixerModel.focusFaderPosition, accuracy: 1e-9,
                       "others sit at the −12 dB fader position")
        XCTAssertEqual(MixerModel.focusAttenuationDB, -12.0)
        XCTAssertEqual(MixerModel.focusFaderPosition, 0.25118864315095795, accuracy: 1e-12,
                       "20·log10(0.251…) = −12 dB")
        XCTAssertEqual(model.resolvedGainDB(for: .instrumental), -12.0, accuracy: 1e-9)
    }

    func testFocusNeverHardMutesOthers() {
        let model = mixer(focus: .instrumental)
        XCTAssertGreaterThan(model.resolvedGain(for: .t1), 0,
                             "D-12: focus ATTENUATES, never mutes — stems bleed")
    }

    func testFocusWithNoTargetIsAllUnity() {
        let model = mixer(focus: nil)
        for part in [Part.t1, .instrumental] {
            XCTAssertEqual(model.resolvedGain(for: part), 1.0, accuracy: 1e-9)
        }
    }

    func testAllVoicesPresetUnity() {
        var model = mixer()
        model.applyAllVoices()
        XCTAssertEqual(model.preset, .allVoices)
        XCTAssertEqual(model.resolvedGain(for: .instrumental), 1.0, accuracy: 1e-9)
    }

    // MARK: - Mute / solo (explicit, honest)

    func testMuteZeroesTheLane() {
        var model = mixer(focus: nil)
        model.setMuted(true, for: .instrumental)
        XCTAssertEqual(model.resolvedGain(for: .instrumental), 0)
        XCTAssertEqual(model.resolvedGain(for: .t1), 1.0, accuracy: 1e-9,
                       "mute is per-lane")
    }

    func testExplicitSoloHardMutesOthers() {
        var model = mixer(focus: nil)
        model.setSoloed(true, for: .instrumental)
        XCTAssertEqual(model.resolvedGain(for: .instrumental), 1.0, accuracy: 1e-9)
        XCTAssertEqual(model.resolvedGain(for: .t1), 0,
                       "explicit solo mutes other lanes (honest labeling duty)")
        // Un-solo restores.
        model.setSoloed(false, for: .instrumental)
        XCTAssertEqual(model.resolvedGain(for: .t1), 1.0, accuracy: 1e-9)
    }

    func testUnionOfMultipleSolos() {
        var model = MixerModel(parts: [.t1, .t2, .instrumental], focusTarget: nil)
        model.setSoloed(true, for: .t1)
        model.setSoloed(true, for: .t2)
        XCTAssertEqual(model.resolvedGain(for: .t2), 1.0, accuracy: 1e-9)
        XCTAssertEqual(model.resolvedGain(for: .t1), 1.0, accuracy: 1e-9)
        XCTAssertEqual(model.resolvedGain(for: .instrumental), 0)
    }

    func testFaderEditMarksCustom() {
        var model = mixer(focus: .t1)
        XCTAssertEqual(model.preset, .focus)
        model.setFader(0.5, for: .instrumental)
        XCTAssertEqual(model.preset, .custom)
        XCTAssertEqual(model.resolvedGain(for: .instrumental), 0.5, accuracy: 1e-9)
    }

    func testFaderClampsToUnitInterval() {
        var model = mixer(focus: nil)
        model.setFader(1.7, for: .t1)
        XCTAssertEqual(model.resolvedGain(for: .t1), 1.0, accuracy: 1e-9)
        model.setFader(-3, for: .t1)
        XCTAssertEqual(model.resolvedGain(for: .t1), 0, accuracy: 1e-9)
    }

    // MARK: - Glide envelope

    func testGlideIs15MSLinearSteps() {
        let samples = MixerModel.glideSamples(from: 0.0, to: 1.0)
        XCTAssertEqual(samples.count, 8, "15 ms / 2 ms ≈ 8 deterministic steps")
        XCTAssertEqual(samples.first!, 0.125, accuracy: 1e-9, "first step, never the jump")
        XCTAssertEqual(samples.last!, 1.0, accuracy: 1e-9, "ends exactly at target")
        for (a, b) in zip(samples, samples.dropFirst()) {
            XCTAssertEqual(b - a, 0.125, accuracy: 1e-9, "linear ramp, no zipper")
        }
    }

    func testGlideDownAndEqualValues() {
        let down = MixerModel.glideSamples(from: 1.0, to: 0.25)
        XCTAssertEqual(down.last!, 0.25, accuracy: 1e-9)
        XCTAssertLessThan(down.first!, 1.0)
        let noOp = MixerModel.glideSamples(from: 0.5, to: 0.5)
        XCTAssertTrue(noOp.allSatisfy { $0 == 0.5 },
                      "no-op glide = deterministic steps all at target")
    }

    // MARK: - Transport loop math

    func testLoopWrapsStablyInsideRegion() {
        var t = TransportModel(duration_s: 100)
        t.state = .playing
        t.setLoop(start_s: 10, end_s: 20)
        t.position_s = 10
        t.tick(dt: 12.0) // flies past 20 → 22
        XCTAssertEqual(t.position_s, 12.0, accuracy: 1e-9,
                       "wraps to lowerBound + overshoot remainder (22 − 10)")
        for _ in 0..<50 {
            t.tick(dt: 1.0)
            if let loop = t.loop {
                XCTAssertTrue(loop.contains(t.position_s) || t.position_s == loop.lowerBound,
                              "position never escapes the region — stable loop")
            }
        }
    }

    func testSeekOutsideRegionReleasesLoop() {
        var t = TransportModel(duration_s: 100)
        t.setLoop(start_s: 10, end_s: 20)
        t.seek(to: 50)
        XCTAssertNil(t.loop, "seeking outside the region releases the loop")
        XCTAssertFalse(t.state == .playing, "seek does not start playback")
    }

    func testDegenerateDragIsNoLoop() {
        var t = TransportModel(duration_s: 100)
        t.setLoop(start_s: 40, end_s: 40.2)
        XCTAssertNil(t.loop, "sub-half-second drags are treated as no loop")
    }

    func testEndOfSongStopsPlaybackWithoutLoop() {
        var t = TransportModel(duration_s: 5)
        t.state = .playing
        t.tick(dt: 6.0)
        XCTAssertEqual(t.position_s, 5, accuracy: 1e-9)
        XCTAssertEqual(t.state, .stopped)
    }
}
