import XCTest
@testable import EngineCore

// P-202 L2 — separation channel-layout adaptation (portable core; Linux docker).
//
// The separation path has three layouts (mix / processing / stems) — see
// SeparationChannels' doc comment. These tests pin the conversions so the
// Apple-only DemucsEngine (which cannot run on Linux) inherits proven math.

final class SeparationChannelsTests: XCTestCase {

    /// Mono mix → processing layout: each sample duplicated to L/R.
    func testUpmixMonoDuplicatesToStereo() throws {
        let mono: [Float] = [0.1, 0.2, 0.3]
        let stereo = try SeparationChannels.upmixToStereo(frames: mono, channels: 1)
        XCTAssertEqual(stereo.count, 6)
        XCTAssertEqual(stereo[0], 0.1, accuracy: 1e-6)
        XCTAssertEqual(stereo[1], 0.1, accuracy: 1e-6)
        XCTAssertEqual(stereo[2], 0.2, accuracy: 1e-6)
        XCTAssertEqual(stereo[3], 0.2, accuracy: 1e-6)
        XCTAssertEqual(stereo[4], 0.3, accuracy: 1e-6)
        XCTAssertEqual(stereo[5], 0.3, accuracy: 1e-6)
    }

    /// Stereo mix → processing layout: passthrough, no copy semantics change.
    func testUpmixStereoIsPassthrough() throws {
        let stereo: [Float] = [0.1, 0.9, 0.2, 0.8]
        let out = try SeparationChannels.upmixToStereo(frames: stereo, channels: 2)
        XCTAssertEqual(out, stereo)
    }

    /// The mix policy is {1, 2} channels (D-8) — anything else is a contract
    /// violation, never a silent fold.
    func testUpmixRejectsUnsupportedChannelCount() {
        XCTAssertThrowsError(try SeparationChannels.upmixToStereo(frames: [0.1, 0.2, 0.3], channels: 3)) { error in
            XCTAssertEqual(error as? SeparationChannels.ChannelError,
                           .unsupportedChannelCount(3))
        }
        XCTAssertThrowsError(try SeparationChannels.upmixToStereo(frames: [0.1, 0.2, 0.3], channels: 0))
    }

    /// A sample count that is not a whole number of frames is rejected (the
    /// driver/engine length contracts are frame-exact).
    func testUpmixRejectsUnalignedSamples() {
        XCTAssertThrowsError(try SeparationChannels.upmixToStereo(frames: [0.1, 0.2, 0.3], channels: 2)) { error in
            XCTAssertEqual(error as? SeparationChannels.ChannelError,
                           .notFrameAligned(samples: 3, channels: 2))
        }
    }

    /// Processing layout → voice-stem layout (D-8: voice MONO): channel mean.
    func testToMonoIsChannelMean() throws {
        let stereo: [Float] = [1.0, 0.0, -1.0, 1.0, 0.5, 0.5]
        let mono = try SeparationChannels.toMono(stereo: stereo)
        XCTAssertEqual(mono.count, 3)
        XCTAssertEqual(mono[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(mono[1], 0.0, accuracy: 1e-6)
        XCTAssertEqual(mono[2], 0.5, accuracy: 1e-6)
    }

    /// The engine's output layout follows the driver's channel contract:
    /// 2 = passthrough, 1 = mono fold.
    func testFromStereoLayoutSelection() throws {
        let stereo: [Float] = [1.0, 0.0, 0.2, 0.4]
        XCTAssertEqual(try SeparationChannels.fromStereo(stereo: stereo, channels: 2), stereo)
        let mono = try SeparationChannels.fromStereo(stereo: stereo, channels: 1)
        XCTAssertEqual(mono.count, 2)
        XCTAssertEqual(mono[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(mono[1], 0.3, accuracy: 1e-6)
        XCTAssertThrowsError(try SeparationChannels.fromStereo(stereo: stereo, channels: 3))
    }
}
