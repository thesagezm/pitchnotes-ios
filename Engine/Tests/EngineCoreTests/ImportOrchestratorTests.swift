import Foundation
import XCTest
@testable import EngineCore

// P-202 L4: the REAL import path — atomic bundle staging (C-2.2), the
// decode → separate → assemble orchestration, C-8 progress monotonicity across
// stages, and the all-or-nothing cleanup guarantee (a cancelled or failed
// import leaves NO partial bundle and NO residue).
//
// The conformers here are FAKES (portable, Linux-testable). The real ones are
// the Apple-side ALAC encoder (P-204, ImportKit) and DemucsEngine's chunked
// separation (P-202 L2).

final class ImportOrchestratorTests: XCTestCase {

    private func tempDir(_ name: String) -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("p202l4-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func writePcm16Wav(url: URL, frames: [Float], sampleRate: Int = 44100,
                               channels: Int = 1) throws {
        var data = Data()
        func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        var payload = Data()
        for f in frames {
            let v = Int16(max(-32768, min(32767, Int(f * 32767.0)))).littleEndian
            withUnsafeBytes(of: v) { payload.append(contentsOf: $0) }
        }
        ascii("RIFF"); u32(UInt32(36 + payload.count)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        ascii("data"); u32(UInt32(payload.count))
        data.append(payload)
        try data.write(to: url)
    }

    private func sourceWav(_ dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("source.wav")
        let n = 44100 / 2
        var frames = [Float](repeating: 0, count: n)
        for i in 0..<n {
            frames[i] = Float(sin(2.0 * Double.pi * 440.0 * Double(i) / 44100.0)) * 0.5
        }
        try writePcm16Wav(url: url, frames: frames)
        return url
    }

    // MARK: - Fakes

    /// Fake separator: writes two stem files into a scratch dir it owns and
    /// hands the orchestrator the cleanup closure for that dir.
    private func fakeSeparator(scratch: URL,
                               progressFractions: [Double] = [0.05, 0.45, 0.90],
                               failWith: Error? = nil,
                               onSeparate: (@Sendable () async -> Void)? = nil)
        -> ImportOrchestrator.SeparationRun {
        let scratch = scratch
        return { [scratch] mix, progress in
            let dir = scratch.appendingPathComponent("sep-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let vocals = dir.appendingPathComponent("vocals.wav")
            let instrumental = dir.appendingPathComponent("instrumental.wav")
            try Data("vocals".utf8).write(to: vocals)
            try Data("instrumental".utf8).write(to: instrumental)
            for f in progressFractions {
                progress(ImportProgress(stage: .separating, fraction: f,
                                        detail: "fake window"))
            }
            if let onSeparate { await onSeparate() }
            if let failWith { throw failWith }
            return SeparationOutput(
                stems: [.vocals: vocals, .instrumental: instrumental],
                cleanup: { try? FileManager.default.removeItem(at: dir) })
        }
    }

    /// Fake encoder: writes a byte marker and reports the requested channel
    /// count (so the D-8 check can be exercised).
    private struct FakeEncoder: StemEncoding {
        var channels: (Part) -> Int = { $0 == .instrumental ? 2 : 1 }
        var failWith: Error?

        func encodeStem(source: URL, destination: URL, part: Part) throws -> Int {
            if let failWith { throw failWith }
            let data = try Data(contentsOf: source)
            try data.write(to: destination)
            return channels(part)
        }
    }

    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [ImportProgress] = []
        func append(_ p: ImportProgress) {
            lock.lock(); entries.append(p); lock.unlock()
        }
        var all: [ImportProgress] {
            lock.lock(); defer { lock.unlock() }; return entries
        }
    }

    // MARK: - BundleStaging (C-2.2 / C-9 rule 4)

    func testBundleIDRejectsPathTraversalAndEmptyIDs() {
        for bad in ["", ".", "..", "../evil", "a/b", "a\\b", ".hidden", "with space", "x\0y"] {
            XCTAssertFalse(BundleStaging.isValidBundleID(bad),
                           "id \(bad.debugDescription) must be rejected")
        }
        for good in ["01JABCDEFGHJKMNPQRSTVWXYZ", "abc-123_XYZ"] {
            XCTAssertTrue(BundleStaging.isValidBundleID(good),
                          "id \(good) must be accepted")
        }
        XCTAssertThrowsError(try BundleStaging(libraryRoot: URL(fileURLWithPath: "/tmp"),
                                                bundleID: "../evil"))
    }

    func testStagingPublishIsAtomicAndDiscardRemovesIt() throws {
        let root = tempDir("staging")
        defer { try? FileManager.default.removeItem(at: root) }
        let stage = try BundleStaging(libraryRoot: root, bundleID: "BUNDLE1")
        try stage.create()
        XCTAssertTrue(stage.hasStaging)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.stagingURL.path))
        // Nothing is visible under the final name before the publish.
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.publishedURL.path))

        try Data("x".utf8).write(to: stage.stagingURL.appendingPathComponent("song.json"))
        try stage.publish()
        XCTAssertFalse(stage.hasStaging)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.publishedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.stagingURL.path))

        // A second publish of the same id refuses to replace published data.
        let again = try BundleStaging(libraryRoot: root, bundleID: "BUNDLE1")
        try again.create()
        XCTAssertThrowsError(try again.publish())

        // discard() removes the staging dir and never throws.
        again.discard()
        XCTAssertFalse(again.hasStaging)
    }

    // MARK: - The import path

    func testSuccessfulImportPublishesValidBundle() async throws {
        let work = tempDir("success")
        defer { try? FileManager.default.removeItem(at: work) }
        let library = work.appendingPathComponent("library", isDirectory: true)
        let source = try sourceWav(work)

        let log = ProgressLog()
        let emitter = ImportProgressEmitter()
        emitter.setHandler { log.append($0) }

        let outcome = try await ImportOrchestrator.run(
            source: source,
            libraryRoot: library,
            decoder: WavSourceDecoder(),
            separator: fakeSeparator(scratch: work),
            encoder: FakeEncoder(),
            emitter: emitter,
            config: .init(title: "Test Hymn"))

        // The bundle is published under its id; song.json is the marker.
        XCTAssertEqual(outcome.bundleID, outcome.manifest.id)
        XCTAssertEqual(outcome.bundleURL.lastPathComponent, outcome.manifest.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.bundleURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outcome.bundleURL.appendingPathComponent("song.json").path))
        // No staging directory survives a successful publish.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: library.appendingPathComponent(outcome.bundleID + ".tmp").path))

        // The published bundle validates against the contract (V1–V15).
        let validation = BundleValidator.validate(bundleDirectory: outcome.bundleURL)
        XCTAssertTrue(validation.isValid, "violations: \(validation.violations)")

        // D-8 channel policy is recorded per stem.
        let vocals = outcome.manifest.parts.first { $0.part == .vocals }
        let instrumental = outcome.manifest.parts.first { $0.part == .instrumental }
        XCTAssertEqual(vocals?.channels, 1)
        XCTAssertEqual(instrumental?.channels, 2)
        XCTAssertEqual(vocals?.stemFile, "stems/VOCALS.m4a")
        XCTAssertEqual(instrumental?.stemFile, "stems/INSTRUMENTAL.m4a")
        XCTAssertTrue(outcome.manifest.hasInstrumental)

        // C-8: all three stages reported, monotonic, 1.0 only at completion.
        let entries = log.all
        XCTAssertTrue(entries.contains { $0.stage == .decoding })
        XCTAssertTrue(entries.contains { $0.stage == .separating })
        XCTAssertTrue(entries.contains { $0.stage == .assembling })
        for (a, b) in zip(entries, entries.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.fraction, a.fraction,
                                        "progress must never decrease: \(a) → \(b)")
        }
        XCTAssertEqual(entries.last?.fraction, 1.0)
        XCTAssertEqual(entries.last?.stage, .assembling)
    }

    func testCancelledImportLeavesNoBundleAndNoResidue() async throws {
        let work = tempDir("cancel")
        defer { try? FileManager.default.removeItem(at: work) }
        let library = work.appendingPathComponent("library", isDirectory: true)
        let source = try sourceWav(work)

        let emitter = ImportProgressEmitter()
        let task = Task {
            try await ImportOrchestrator.run(
                source: source,
                libraryRoot: library,
                decoder: WavSourceDecoder(),
                separator: fakeSeparator(scratch: work, onSeparate: {
                    // Cancel while the separation is "running".
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }),
                encoder: FakeEncoder(),
                emitter: emitter)
        }
        // Let the decode finish, then cancel.
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled import must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }

        // NO partial bundle, NO staging dir, no scratch left behind.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "library root must hold no bundle/staging: \(leftovers)")
        let scratch = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
        XCTAssertFalse(scratch.contains { $0.hasPrefix("sep-") },
                       "separator scratch must be cleaned up: \(scratch)")
    }

    func testFailureDuringAssemblyRemovesStagingAndPublishesNothing() async throws {
        let work = tempDir("fail")
        defer { try? FileManager.default.removeItem(at: work) }
        let library = work.appendingPathComponent("library", isDirectory: true)
        let source = try sourceWav(work)

        struct Boom: Error {}
        do {
            _ = try await ImportOrchestrator.run(
                source: source,
                libraryRoot: library,
                decoder: WavSourceDecoder(),
                separator: fakeSeparator(scratch: work),
                encoder: FakeEncoder(failWith: Boom()),
                config: .init(title: "Failing"))
            XCTFail("assembly failure must throw")
        } catch {
            XCTAssertTrue(error is Boom)
        }

        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "no bundle and no staging dir may survive: \(leftovers)")
    }

    func testSeparationFailureLeavesNothingPublished() async throws {
        let work = tempDir("sepfail")
        defer { try? FileManager.default.removeItem(at: work) }
        let library = work.appendingPathComponent("library", isDirectory: true)
        let source = try sourceWav(work)

        struct SepBoom: Error {}
        do {
            _ = try await ImportOrchestrator.run(
                source: source,
                libraryRoot: library,
                decoder: WavSourceDecoder(),
                separator: fakeSeparator(scratch: work, failWith: SepBoom()),
                encoder: FakeEncoder())
            XCTFail("separation failure must throw")
        } catch {
            XCTAssertTrue(error is SepBoom)
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testD8ChannelMismatchIsRejectedAndNothingIsPublished() async throws {
        let work = tempDir("d8")
        defer { try? FileManager.default.removeItem(at: work) }
        let library = work.appendingPathComponent("library", isDirectory: true)
        let source = try sourceWav(work)

        // VOCALS encoded as stereo violates D-8 (voice stems are MONO).
        let encoder = FakeEncoder(channels: { _ in 2 })
        do {
            _ = try await ImportOrchestrator.run(
                source: source,
                libraryRoot: library,
                decoder: WavSourceDecoder(),
                separator: fakeSeparator(scratch: work),
                encoder: encoder)
            XCTFail("D-8 violation must throw")
        } catch {
            guard case EngineError.contractViolation = error else {
                return XCTFail("expected contractViolation, got \(error)")
            }
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testAcapellaSourceOmitsInstrumentalStemAndEntry() async throws {
        let work = tempDir("acapella")
        defer { try? FileManager.default.removeItem(at: work) }
        let library = work.appendingPathComponent("library", isDirectory: true)
        let source = try sourceWav(work)

        // D-9: near-silent instrumental ⇒ hasInstrumental = false ⇒ NO
        // INSTRUMENTAL stem on disk and NO INSTRUMENTAL entry (V15).
        let outcome = try await ImportOrchestrator.run(
            source: source,
            libraryRoot: library,
            decoder: WavSourceDecoder(),
            separator: fakeSeparator(scratch: work),
            encoder: FakeEncoder(),
            config: .init(title: "Acapella",
                          instrumentalPresence: { _ in false }))

        XCTAssertFalse(outcome.manifest.hasInstrumental)
        XCTAssertFalse(outcome.manifest.parts.contains { $0.part == .instrumental })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outcome.bundleURL.appendingPathComponent("stems/INSTRUMENTAL.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outcome.bundleURL.appendingPathComponent("stems/VOCALS.m4a").path))
        let validation = BundleValidator.validate(bundleDirectory: outcome.bundleURL)
        XCTAssertTrue(validation.isValid, "violations: \(validation.violations)")
    }

    func testProgressBandsAreDisjointAndMonotonic() async throws {
        let work = tempDir("bands")
        defer { try? FileManager.default.removeItem(at: work) }
        let library = work.appendingPathComponent("library", isDirectory: true)
        let source = try sourceWav(work)

        let log = ProgressLog()
        let emitter = ImportProgressEmitter()
        emitter.setHandler { log.append($0) }

        _ = try await ImportOrchestrator.run(
            source: source,
            libraryRoot: library,
            decoder: WavSourceDecoder(),
            separator: fakeSeparator(scratch: work, progressFractions: [0.05, 0.5, 0.9]),
            encoder: FakeEncoder(),
            emitter: emitter)

        let entries = log.all
        for e in entries {
            switch e.stage {
            case .decoding: XCTAssertLessThanOrEqual(e.fraction, 0.05)
            case .separating: XCTAssertGreaterThanOrEqual(e.fraction, 0.05)
            case .assembling: XCTAssertGreaterThanOrEqual(e.fraction, 0.90)
            }
        }
        for (a, b) in zip(entries, entries.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.fraction, a.fraction)
        }
    }

    func testSecondImportInSameProcessIsNotClampedToPreviousCompletion() async throws {
        let work = tempDir("repeat")
        defer { try? FileManager.default.removeItem(at: work) }
        let library = work.appendingPathComponent("library", isDirectory: true)
        let source = try sourceWav(work)

        let log = ProgressLog()
        let emitter = ImportProgressEmitter()
        emitter.setHandler { log.append($0) }

        _ = try await ImportOrchestrator.run(source: source, libraryRoot: library,
                                             decoder: WavSourceDecoder(),
                                             separator: fakeSeparator(scratch: work),
                                             encoder: FakeEncoder(), emitter: emitter)
        let firstCount = log.all.count
        _ = try await ImportOrchestrator.run(source: source, libraryRoot: library,
                                             decoder: WavSourceDecoder(),
                                             separator: fakeSeparator(scratch: work),
                                             encoder: FakeEncoder(), emitter: emitter)
        let second = log.all.dropFirst(firstCount)
        XCTAssertFalse(second.isEmpty)
        // The second import starts below 1.0 again (the monotonic baseline was
        // reset by beginImport()).
        XCTAssertLessThan(second.first?.fraction ?? 1.0, 1.0)
    }

    // MARK: - Cleanup never masks the real error (P-204, macOS CI run 45143126945)

    /// A missing path is not a cleanup failure — the removal is idempotent.
    func testRemoveIfPresentOnAMissingPathReportsNoFailure() {
        let missing = URL(fileURLWithPath: "/tmp/pitchnotes-does-not-exist-\(UUID().uuidString)")
        XCTAssertNil(ImportOrchestrator.removeIfPresent(missing))
    }

    /// An existing path IS removed, and the removal reports no failure.
    func testRemoveIfPresentRemovesAnExistingPath() throws {
        let work = tempDir("remove")
        defer { try? FileManager.default.removeItem(at: work) }
        let victim = work.appendingPathComponent("victim", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        XCTAssertNil(ImportOrchestrator.removeIfPresent(victim))
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
    }

    /// The cleanup note is APPENDED to the original error — the error's TYPE
    /// and its original message survive (a failed import must surface the
    /// REAL failure).
    func testCleanupNotesAreAppendedAndTheErrorTypeIsPreserved() {
        let original = EngineError.importFailed("ALAC encode failed for VOCALS")
        let decorated = ImportOrchestrator.preserving(original, cleanupNotes: ["could not remove work"])
        guard let engineError = decorated as? EngineError else {
            return XCTFail("the error type must be preserved")
        }
        guard case .importFailed(let message) = engineError else {
            return XCTFail("the error case must be preserved")
        }
        XCTAssertTrue(message.contains("ALAC encode failed for VOCALS"),
                      "the original message must survive: \(message)")
        XCTAssertTrue(message.contains("could not remove work"),
                      "the cleanup note must be appended: \(message)")
    }

    /// Without a cleanup note the error is returned UNCHANGED (no suffix, no
    /// wrapping).
    func testPreservingWithoutNotesReturnsTheErrorUnchanged() {
        let original = EngineError.unsupportedFormat("bad container")
        let result = ImportOrchestrator.preserving(original, cleanupNotes: [])
        guard let engineError = result as? EngineError else {
            return XCTFail("the error type must be preserved")
        }
        guard case .unsupportedFormat(let message) = engineError else {
            return XCTFail("the error case must be preserved")
        }
        XCTAssertEqual(message, "bad container")
    }
}
