// MicPermissionFlowTests (J-102 AC: "permission flows tested incl. deny") —
// the pure state machine's transitions and gate precedence.

import XCTest
import PitchLogic

final class MicPermissionFlowTests: XCTestCase {

    func testNotDeterminedAsksPermission() {
        let flow = MicPermissionFlow()
        XCTAssertEqual(flow.permission, .notDetermined)
        XCTAssertEqual(flow.gate, .askPermission)
    }

    func testGrantedRequestLeadsToReady() {
        var flow = MicPermissionFlow()
        flow.requestResult(true)
        XCTAssertEqual(flow.permission, .granted)
        XCTAssertEqual(flow.gate, .ready)
        XCTAssertFalse(flow.shouldResumeAfterInterruption)
    }

    func testDeniedRequestLeadsToSettingsScreenNotCrash() {
        var flow = MicPermissionFlow()
        flow.requestResult(false) // the deny path — designed state, not an error
        XCTAssertEqual(flow.permission, .denied)
        XCTAssertEqual(flow.gate, .deniedSettings)
        // An interruption during denial must NOT hide the Settings screen.
        flow.interruptionBegan()
        XCTAssertEqual(flow.gate, .deniedSettings, "denied takes precedence over interruption")
    }

    func testRequestResultIsIdempotentAfterDecision() {
        var flow = MicPermissionFlow()
        flow.requestResult(true)
        flow.requestResult(false) // a second system answer cannot demote a grant
        XCTAssertEqual(flow.permission, .granted)
        XCTAssertEqual(flow.gate, .ready)
    }

    func testInterruptionShowsPausedBannerAndResumeOption() {
        var flow = MicPermissionFlow()
        flow.requestResult(true)
        flow.interruptionBegan()
        XCTAssertEqual(flow.gate, .interrupted)
        flow.interruptionEnded(shouldResume: true)
        XCTAssertEqual(flow.gate, .ready)
        XCTAssertTrue(flow.shouldResumeAfterInterruption, "ended with .shouldResume → auto-resume safe")
    }

    func testInterruptionWithoutResumeFlagForcesManualRestart() {
        var flow = MicPermissionFlow()
        flow.requestResult(true)
        flow.interruptionBegan()
        flow.interruptionEnded(shouldResume: false)
        XCTAssertEqual(flow.gate, .ready)
        XCTAssertFalse(flow.shouldResumeAfterInterruption, "no .shouldResume → UI must offer manual restart")
    }

    func testInterruptionClearedByNextInterruptionCycle() {
        var flow = MicPermissionFlow()
        flow.requestResult(true)
        flow.interruptionBegan()
        flow.interruptionEnded(shouldResume: true)
        flow.interruptionBegan() // second call (backgrounded during a call)
        XCTAssertEqual(flow.gate, .interrupted)
        XCTAssertFalse(flow.shouldResumeAfterInterruption, "new interruption resets the resume hint")
        flow.interruptionEnded(shouldResume: true)
        XCTAssertEqual(flow.gate, .ready)
    }
}
