// LivePitchEngineSwapTests (J-105) — the contract-side proof of the C-6.0
// swap: REAL ribbon frames carry the contract identity, and the PitchLogic
// display adapter derives from (never duplicates) the EngineCore C-6.1 table.
//
// The App-side glue (LivePitchEngineRibbonSource / MicChunkProviding /
// PlaceholderSwiftF0Inference / RibbonModel.SourceMode) lives in the app
// target (build-ipa compiles it); what logic-tests can and must pin is the
// ENGINE contract the swap relies on — same rule as the J-101 mapper tests.

import XCTest
import EngineCore
import PitchLogic

final class LivePitchEngineSwapTests: XCTestCase {

    /// Honest zero seam (real ORT inference arrives with PitchORT/X-008) —
    /// per-frame zeros: real array SHAPE, zero confidence = unvoiced.
    private struct ZeroSwiftF0Inference: SwiftF0Inference {
        func run(audio: [Float], fmin: Float, fmax: Float) throws -> (pitch: [Double], confidence: [Float]) {
            let frames = audio.count / 256
            return (pitch: [Double](repeating: 0, count: frames),
                    confidence: [Float](repeating: 0, count: frames))
        }
    }

    // MARK: - C-6.0 identity off REAL ribbon frames

    func testRibbonFramesCarryContractIdentity() throws {
        // 220 Hz sine (above the 80 Hz MPM floor, mid-band), continuous
        // phase, pushed as hop-aligned 256-sample chunks like the capture
        // seam delivers (P-104 hop-aligned MicChunks).
        let facade = LivePitchFacade(swiftf0Inference: ZeroSwiftF0Inference(), vadInference: nil)
        let sr = RibbonSpec.sampleRate
        let hop = RibbonSpec.hop
        let totalSamples = 8 * hop // 2048 → first window (1024) fills at chunk 4
        let sine = (0..<totalSamples).map { 0.5 * Float(sin(2.0 * .pi * 220.0 * Double($0) / Double(sr))) }

        var last: PitchFrame?
        var framesSeen = 0
        for chunkIndex in 0..<(totalSamples / hop) {
            let chunk = MicChunk(samples: Array(sine[chunkIndex * hop..<(chunkIndex + 1) * hop]),
                                 sampleRate: sr, captureTime_s: Double(chunkIndex) * 0.016)
            let frame = facade.ribbonFrame(chunk) // C-6.0: causal call ONLY
            XCTAssertGreaterThanOrEqual(frame.confidence, 0)
            XCTAssertLessThanOrEqual(frame.confidence, 1) // V12 contract surface
            XCTAssertEqual(frame.lookahead_ms, 0, "ribbon is the ZERO-lookahead source (C-6.0)")
            if frame.hz > 0 {
                framesSeen += 1
                last = frame
            }
        }

        XCTAssertGreaterThanOrEqual(framesSeen, 2, "window(1024)+8 hops must emit ≥ 2 voiced frames")
        let frame = try XCTUnwrap(last)
        XCTAssertEqual(frame.engine_id, PitchEngineID.ribbonMpmYin.rawValue)
        XCTAssertEqual(frame.engine_id, "RIBBON_MPM_YIN") // C-6.0 rawValue verbatim
        XCTAssertEqual(frame.hz, 220.0, accuracy: 1.0, "real MPM estimate on a clean sine")
        XCTAssertEqual(frame.lookahead_ms, 0)
    }

    func testFacadeDeclaresContractSources() {
        let facade = LivePitchFacade(swiftf0Inference: ZeroSwiftF0Inference(), vadInference: nil)
        XCTAssertEqual(facade.ribbonSource, .ribbonMpmYin)
        XCTAssertEqual(facade.gradingSource, .swiftf0)
        XCTAssertEqual(LivePitchFacade.gradingLookaheadMs, 176, "C-6.0 contract constant")
    }

    func testUnvoicedSilenceFramesStayHonest() {
        // Silence in → the REAL ribbon answers unvoiced (hz 0) with identity
        // intact — the debug screen's pre-capture state must never fake signal.
        let facade = LivePitchFacade(swiftf0Inference: ZeroSwiftF0Inference(), vadInference: nil)
        let silence = MicChunk(samples: [Float](repeating: 0, count: Int(RibbonSpec.hop)),
                               sampleRate: RibbonSpec.sampleRate, captureTime_s: 0)
        var frame = facade.ribbonFrame(silence)
        // Feed enough silence for a full window (4 hops).
        for i in 1..<6 {
            frame = facade.ribbonFrame(MicChunk(samples: [Float](repeating: 0, count: Int(RibbonSpec.hop)),
                                                sampleRate: RibbonSpec.sampleRate,
                                                captureTime_s: Double(i) * 0.016))
        }
        XCTAssertEqual(frame.engine_id, "RIBBON_MPM_YIN")
        XCTAssertEqual(frame.lookahead_ms, 0)
        XCTAssertEqual(frame.hz, 0, "silence is unvoiced — honest zero, not a fake pitch")
    }

    // MARK: - PartRangeChips derives from (not duplicates) the EngineCore table

    func testChipsAdapterMirrorsEngineCoreTable() {
        // Every display row must EQUAL the EngineCore contract row it derives
        // from — the adapter owns zero contract values.
        for (part, preset) in EngineCore.PartRangePresets.all {
            let chip = PartRangeChips.range(for: part)
            XCTAssertNotNil(chip, "\(part.rawValue) missing from chips")
            XCTAssertEqual(chip?.part, preset.part)
            XCTAssertEqual(chip?.presetName, preset.presetName)
            XCTAssertEqual(chip?.midiLow, preset.midiLow)
            XCTAssertEqual(chip?.midiHigh, preset.midiHigh)
            XCTAssertEqual(chip?.hzLow, preset.fmin, accuracy: 0.001)
            XCTAssertEqual(chip?.hzHigh, preset.fmax, accuracy: 0.001)
        }
        XCTAssertEqual(PartRangeChips.all.count, 7)
        XCTAssertNil(PartRangeChips.range(for: .vp))
        XCTAssertNil(PartRangeChips.range(for: .lead))
        XCTAssertNil(PartRangeChips.range(for: .instrumental))
    }

    func testChipsDisplayDerivations() {
        XCTAssertEqual(PartRangeChips.bass.displayName, "Bass E2–G3")
        XCTAssertEqual(PartRangeChips.bass.centerCents, 4750, "center of E2(40)…G3(55) — follow-window init")
    }
}
