import XCTest
import EngineCore
@testable import PitchLogic

// J-201 AC "progress/cancel tested" — the import flow's pure decision layer:
// C-8 progress enforcement, cancellation semantics, error mapping, disk
// budget, thermal notices, and the JSON index (D-4 v0) with the C-2.2
// consumer rule.

final class ImportProgressTrackerTests: XCTestCase {

    // MARK: Overall fraction passthrough (C-8: the engine weights its stages)

    func testOverallFractionPassesThroughWithinStage() {
        var t = ImportProgressTracker()
        t.feed(stage: .decoding, fraction: 0.05, detail: nil)
        XCTAssertEqual(t.snapshot?.fraction ?? 0, 0.05, accuracy: 1e-12)
        t.feed(stage: .separating, fraction: 0.475, detail: nil)
        XCTAssertEqual(t.snapshot?.fraction ?? 0, 0.475, accuracy: 1e-12)
        XCTAssertEqual(t.snapshot?.stage, .separating)
        t.feed(stage: .assembling, fraction: 0.925, detail: nil)
        XCTAssertEqual(t.snapshot?.fraction ?? 0, 0.925, accuracy: 1e-12)
    }

    func testOverallStaysInUnitInterval() {
        var t = ImportProgressTracker()
        for f in stride(from: 0.0, through: 1.0, by: 0.1) {
            for stage in ImportStage.allCases {
                t.feed(stage: stage, fraction: f, detail: nil)
                let v = t.snapshot?.fraction ?? 0
                XCTAssertTrue(v >= 0 && v <= 1, "\(stage) \(f) → \(v)")
            }
        }
    }

    // MARK: Monotonicity (C-8: never decreases)

    func testWithinStageRegressionIsClampedAndCounted() {
        var t = ImportProgressTracker()
        t.feed(stage: .separating, fraction: 0.6, detail: nil)
        let before = t.snapshot?.fraction ?? 0
        t.feed(stage: .separating, fraction: 0.4, detail: nil)
        XCTAssertEqual(t.snapshot?.fraction, before, "overall must never decrease")
        XCTAssertEqual(t.clippedNonMonotonicEvents, 1)
    }

    func testBackwardsStageTransitionIsRejected() {
        var t = ImportProgressTracker()
        t.feed(stage: .separating, fraction: 0.2, detail: nil)
        let before = t.snapshot
        let result = t.feed(stage: .decoding, fraction: 0.9, detail: "regressed")
        XCTAssertEqual(result, before, "out-of-order stage event must not move the bar")
        XCTAssertEqual(t.rejectedEvents, 1)
        XCTAssertNotEqual(t.snapshot?.stage, .decoding)
    }

    func testSameStageAndForwardTransitionsAccepted() {
        var t = ImportProgressTracker()
        XCTAssertNotNil(t.feed(stage: .decoding, fraction: 1.0, detail: nil))
        XCTAssertNotNil(t.feed(stage: .separating, fraction: 0.0, detail: nil))
        XCTAssertEqual(t.snapshot?.stage, .separating)
        XCTAssertEqual(t.rejectedEvents, 0)
    }

    // MARK: 1.0 only at completion (C-8 / P-202 AC)

    func testPreCompletionOneIsCappedAndCounted() {
        var t = ImportProgressTracker()
        t.feed(stage: .assembling, fraction: 1.0, detail: nil)
        XCTAssertLessThan(t.snapshot?.fraction ?? 1, 1.0)
        XCTAssertEqual(t.clippedNonMonotonicEvents, 1)
        XCTAssertFalse(t.isComplete)
    }

    func testFinishIsTheOnlyPathToExactOne() {
        var t = ImportProgressTracker()
        t.feed(stage: .assembling, fraction: 0.99, detail: nil)
        let final = t.finish(detail: "done")
        XCTAssertEqual(final.fraction, 1.0)
        XCTAssertTrue(t.isComplete)
        XCTAssertEqual(t.snapshot?.fraction, 1.0)
    }

    func testEventsAfterFinishAreRejected() {
        var t = ImportProgressTracker()
        t.finish()
        let before = t.snapshot
        t.feed(stage: .decoding, fraction: 0.5, detail: nil)
        XCTAssertEqual(t.snapshot, before)
        XCTAssertEqual(t.rejectedEvents, 1)
        XCTAssertEqual(t.snapshot?.fraction, 1.0, "completion never regresses")
    }

    // MARK: Detail passthrough

    func testDetailPassthrough() {
        var t = ImportProgressTracker()
        t.feed(stage: .separating, fraction: 0.3, detail: "chunk 7/40")
        XCTAssertEqual(t.snapshot?.detail, "chunk 7/40")
        t.feed(stage: .separating, fraction: 0.4, detail: nil)
        XCTAssertNil(t.snapshot?.detail)
    }
}

final class ImportFailureMappingTests: XCTestCase {

    func testCancellationErrorMapsToCancelled() {
        XCTAssertEqual(ImportFailure.cause(from: CancellationError()), .cancelled)
    }

    func testEngineErrorsMap() {
        XCTAssertEqual(ImportFailure.cause(from: EngineError.unsupportedFormat("xyz")),
                       .unsupportedFile("xyz"))
        XCTAssertEqual(ImportFailure.cause(from: EngineError.importFailed("bad")),
                       .decodeFailed("bad"))
        XCTAssertEqual(ImportFailure.cause(from: EngineError.separationFailed("s")),
                       .engineFailure("s"))
        // The weights could not be loaded ⇒ the human's next step is the
        // DOWNLOAD, not a retry — so it maps to its own case (session 8).
        XCTAssertEqual(ImportFailure.cause(from: EngineError.modelMissing("m")),
                       .separationUnavailable(
                        "The separation model could not be loaded. Download it again in Settings → Models."))
        XCTAssertEqual(ImportFailure.cause(from: EngineError.contractViolation("v")),
                       .engineFailure("v"))
    }

    func testDiskFullAndPermissionNSErrorMapping() {
        let diskFull = NSError(domain: NSPOSIXErrorDomain, code: 28,
                               userInfo: [NSLocalizedDescriptionKey: "No space left on device"])
        XCTAssertEqual(ImportFailure.cause(from: diskFull), .diskFull(neededBytes: 0, availableBytes: 0))

        // Only ENOSPC (28) maps to disk full — other codes fall through.
        let cocoaOther = NSError(domain: NSCocoaErrorDomain, code: 640, userInfo: nil)
        if case .diskFull = ImportFailure.cause(from: cocoaOther) {
            XCTFail("cocoa 640 must not map to disk full")
        }

        // 257 = NSFileReadNoPermissionDenied (literal — the named constant is
        // not in scope in this SPM target on CI; same precedent as ImportFlowRules).
        let denied = NSError(domain: NSCocoaErrorDomain, code: 257, userInfo: nil)
        XCTAssertEqual(ImportFailure.cause(from: denied), .permissionDenied)
    }

    func testUnknownErrorFallsThrough() {
        struct Weird: Error {}
        if case .unknown = ImportFailure.cause(from: Weird()) {} else {
            XCTFail("unexpected error must land in .unknown")
        }
    }

    func testUserCopyPresentForEveryCase() {
        let cases: [ImportError] = [
            .unsupportedFile("x"), .permissionDenied,
            .diskFull(neededBytes: 1, availableBytes: 0),
            .decodeFailed("x"), .engineFailure("x"),
            .separationUnavailable("x"), .engineUnavailable("x"),
            .cancelled, .unknown("x"),
        ]
        for e in cases {
            XCTAssertFalse(e.title.isEmpty)
            XCTAssertFalse(e.recoverySuggestion.isEmpty)
        }
    }

    /// The specific reason must REACH the screen (session 8): the app has
    /// always written actionable messages into the error cases, and the
    /// failure view used to render only the title + the recovery line — so
    /// "download it in Settings → Models" never appeared.
    func testDetailCarriesTheSpecificReason() {
        XCTAssertEqual(ImportError.separationUnavailable("download the model").detail,
                       "download the model")
        XCTAssertEqual(ImportError.engineUnavailable("no real engine").detail,
                       "no real engine")
        XCTAssertEqual(ImportError.engineFailure("boom").detail, "boom")
        XCTAssertNil(ImportError.cancelled.detail)
        XCTAssertNotNil(ImportError.permissionDenied.detail)
    }

    /// The two new cases must NOT give "retry" advice — the fix is different
    /// for each (download the model / use a real build).
    func testModelAndBuildFailuresGetTheirOwnAdvice() {
        let model = ImportError.separationUnavailable("x")
        XCTAssertTrue(model.recoverySuggestion.contains("Settings → Models"))
        XCTAssertFalse(model.recoverySuggestion.contains("Retrying usually helps"))

        let build = ImportError.engineUnavailable("x")
        XCTAssertTrue(build.recoverySuggestion.contains("build"))
        XCTAssertFalse(build.recoverySuggestion.contains("Retrying usually helps"))
    }

    /// The disk-full state shows needed-vs-available (UX §5.1) — in units the
    /// human can act on, not raw bytes.
    func testDiskFullDetailShowsNeededVersusAvailableInMegabytes() {
        let e = ImportError.diskFull(neededBytes: 2_097_152, availableBytes: 1_048_576)
        let detail = e.detail ?? ""
        XCTAssertTrue(detail.contains("2.0 MB"), detail)
        XCTAssertTrue(detail.contains("1.0 MB"), detail)
        XCTAssertEqual(ImportByteFormat.megabytes(1_048_576), "1.0 MB")
        XCTAssertEqual(ImportByteFormat.megabytes(0), "0.0 MB")
    }
}

final class ImportDiskBudgetTests: XCTestCase {

    func testRequiredBytesUsesSafetyMultiplier() {
        XCTAssertEqual(ImportDiskBudget.requiredBytes(sourceBytes: 1_000_000), 3_000_000)
        XCTAssertEqual(ImportDiskBudget.requiredBytes(sourceBytes: 0), 0)
        XCTAssertEqual(ImportDiskBudget.requiredBytes(sourceBytes: -5), 0, "negative input clamps")
    }

    func testVerdict() {
        XCTAssertEqual(ImportDiskBudget.verdict(sourceBytes: 100, availableBytes: 300), .ok)
        XCTAssertEqual(ImportDiskBudget.verdict(sourceBytes: 100, availableBytes: 301), .ok)
        XCTAssertEqual(
            ImportDiskBudget.verdict(sourceBytes: 100, availableBytes: 299),
            .short(neededBytes: 300, availableBytes: 299))
        XCTAssertEqual(
            ImportDiskBudget.verdict(sourceBytes: 100, availableBytes: -1),
            .short(neededBytes: 300, availableBytes: 0), "negative available clamps")
    }
}

final class ImportThermalGateTests: XCTestCase {

    func testAdviceLevels() {
        XCTAssertEqual(ImportThermalGate.advice(for: .nominal), .none)
        XCTAssertEqual(ImportThermalGate.advice(for: .fair), .none)

        if case .slowDown(let msg) = ImportThermalGate.advice(for: .serious) {
            XCTAssertFalse(msg.isEmpty)
        } else { XCTFail("serious must produce slowDown advice") }

        if case .deferRecommended(let msg) = ImportThermalGate.advice(for: .critical) {
            XCTAssertFalse(msg.isEmpty)
        } else { XCTFail("critical must produce defer advice") }
    }

    func testAdviceMessagesExposed() {
        XCTAssertNil(ImportThermalGate.advice(for: .nominal).message)
        XCTAssertEqual(ImportThermalGate.advice(for: .serious).message,
                       ImportThermalGate.seriousCopy)
        XCTAssertEqual(ImportThermalGate.advice(for: .critical).message,
                       ImportThermalGate.criticalCopy)
    }
}
