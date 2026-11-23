import XCTest
import Foundation
import AVFoundation
import EngineCore
@testable import ImportKit

// P-204 · macOS CI proof of the ALAC stem writer and the REAL import engine
// (X-204 runs `cd Engine/ImportKit && swift test` on macOS).
//
// What these tests prove:
//   1. the ALAC writer produces a REAL ALAC .m4a that AVFoundation decodes
//      back LOSSLESSLY (bit-depth identical to the PCM16 source), at 44.1 kHz
//      with the D-8 channel layout (voice mono / instrumental stereo);
//   2. the real import engine publishes a COMPLETE bundle (stems + song.json),
//      the bundle validates against the contract (V1–V15), `importedBundleID`
//      is published only after the atomic publish (C-9), and the D-9
//      acapella path really omits the INSTRUMENTAL stem.
//
// The separation itself is FAKED here (the real vendor path is the
// separation-spike's job); everything else — the decode, the ALAC encode, the
// assembly, the atomic publish — is the production code.

final class ALACBundleTests: XCTestCase {

    private func tempDir(_ name: String) -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("p204-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ImportKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ImportKit
            .deletingLastPathComponent() // Engine
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Tests/Spikes/Fixtures/\(name)")
    }

    /// A mono/stereo PCM16 stem at a given level (dBFS RMS; nil = silence).
    private static func writeStem(at url: URL, rmsDBFS: Double?, channels: Int) throws {
        let frames = 44100
        var samples = [Float](repeating: 0, count: frames * channels)
        if let rmsDBFS {
            let amplitude = Float(pow(10.0, rmsDBFS / 20.0))
            for f in 0..<frames {
                let value = amplitude * Float(sqrt(2.0))
                    * sin(2.0 * Double.pi * 220.0 * Double(f) / 44100.0)
                for c in 0..<channels { samples[f * channels + c] = value }
            }
        }
        try PCMWavWriter.write(url: url, samples: samples, sampleRate: 44100, channels: channels)
    }

    /// Fake separation: two stems (mono vocals, stereo instrumental) in a
    /// scratch directory the seam cleans up.
    private func fakeSeparator(scratch: URL,
                               instrumentalRMS: Double? = -20)
        -> ImportOrchestrator.SeparationRun {
        let scratch = scratch
        return { _, progress in
            let dir = scratch.appendingPathComponent("sep-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let vocals = dir.appendingPathComponent("vocals.wav")
            let instrumental = dir.appendingPathComponent("instrumental.wav")
            try Self.writeStem(at: vocals, rmsDBFS: -25, channels: 1)
            try Self.writeStem(at: instrumental, rmsDBFS: instrumentalRMS, channels: 2)
            progress(ImportProgress(stage: .separating, fraction: 0.05, detail: "fake"))
            progress(ImportProgress(stage: .separating, fraction: 0.90, detail: "fake"))
            return SeparationOutput(
                stems: [.vocals: vocals, .instrumental: instrumental],
                cleanup: { try? FileManager.default.removeItem(at: dir) })
        }
    }

    /// Decodes an audio file to interleaved float samples (the file's native
    /// rate/channels).
    private func decodeSamples(url: URL) throws -> (samples: [Float], sampleRate: Double, channels: Int) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = Int(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let planes = buffer.floatChannelData else {
            throw EngineError.importFailed("cannot decode \(url.lastPathComponent)")
        }
        try file.read(into: buffer)
        let channels = Int(format.channelCount)
        var interleaved = [Float](repeating: 0, count: frames * channels)
        for c in 0..<channels {
            let plane = planes[c]
            for f in 0..<frames { interleaved[f * channels + c] = plane[f] }
        }
        return (interleaved, format.sampleRate, channels)
    }

    // MARK: - ALAC writer

    func testALACStemWriterRoundTripsLosslessly() throws {
        let dir = tempDir("alac")
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("vocals.wav")
        let destination = dir.appendingPathComponent("VOCALS.m4a")
        try Self.writeStem(at: source, rmsDBFS: -20, channels: 1)

        let channels = try ALACStemWriter().encodeStem(source: source,
                                                       destination: destination,
                                                       part: .vocals)
        XCTAssertEqual(channels, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        // The product is a real m4a/ALAC file: AVFoundation opens it.
        let decoded = try decodeSamples(url: destination)
        XCTAssertEqual(decoded.sampleRate, 44100, accuracy: 0.5)
        XCTAssertEqual(decoded.channels, 1)

        // ALAC is LOSSLESS: the decoded samples match the source (the source
        // was quantized to int16, so the comparison is at int16 precision).
        let original = try decodeSamples(url: source)
        XCTAssertEqual(original.samples.count, decoded.samples.count)
        var maxDelta: Float = 0
        for (a, b) in zip(original.samples, decoded.samples) {
            maxDelta = max(maxDelta, abs(a - b))
        }
        XCTAssertLessThan(maxDelta, 1.0 / 32767.0 * 1.5,
                          "ALAC round-trip must be lossless (max delta \(maxDelta))")
    }

    func testALACStemWriterKeepsStereoInstrumental() throws {
        let dir = tempDir("alac-stereo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("instrumental.wav")
        let destination = dir.appendingPathComponent("INSTRUMENTAL.m4a")
        try Self.writeStem(at: source, rmsDBFS: -20, channels: 2)

        let channels = try ALACStemWriter().encodeStem(source: source,
                                                       destination: destination,
                                                       part: .instrumental)
        XCTAssertEqual(channels, 2)
        let decoded = try decodeSamples(url: destination)
        XCTAssertEqual(decoded.channels, 2)
    }

    // MARK: - The real import engine

    func testImportEnginePublishesCompleteBundle() async throws {
        let dir = tempDir("engine")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = dir.appendingPathComponent("library", isDirectory: true)

        let engine = SongBundleImportEngine(libraryRoot: library,
                                             separator: fakeSeparator(scratch: dir))
        // C-9: nothing is published before an import succeeds.
        XCTAssertNil(engine.importedBundleID)

        let source = fixture("mix44k_short.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let outcome = try await engine.importSong(source: source, title: "Mixed Hymn")

        // C-9: the id is published AFTER the atomic publish.
        XCTAssertEqual(engine.importedBundleID, outcome.bundleID)
        XCTAssertEqual(outcome.bundleID, outcome.manifest.id)
        XCTAssertEqual(outcome.bundleURL.lastPathComponent, outcome.bundleID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.bundleURL.path))

        // The bundle layout (C-2): stems/<PART>.m4a + song.json.
        let vocals = outcome.bundleURL.appendingPathComponent("stems/VOCALS.m4a")
        let instrumental = outcome.bundleURL.appendingPathComponent("stems/INSTRUMENTAL.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: vocals.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: instrumental.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outcome.bundleURL.appendingPathComponent("song.json").path))

        // The published bundle validates against the contract (V1–V15).
        let validation = BundleValidator.validate(bundleDirectory: outcome.bundleURL)
        XCTAssertTrue(validation.isValid, "violations: \(validation.violations)")

        // D-8 channel policy is recorded per stem.
        XCTAssertEqual(outcome.manifest.parts.first { $0.part == .vocals }?.channels, 1)
        XCTAssertEqual(outcome.manifest.parts.first { $0.part == .instrumental }?.channels, 2)

        // D-9: a real accompaniment ⇒ hasInstrumental = true.
        XCTAssertTrue(outcome.manifest.hasInstrumental)

        // The engine-side import cache knows the source hash.
        XCTAssertEqual(engine.cachedBundleID(forSourceHash: outcome.manifest.sourceHash.hex),
                       outcome.bundleID)

        // No staging directory and no scratch stems survive the import.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasSuffix(".tmp") },
                       "no staging directory may survive: \(leftovers)")
        let scratch = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertFalse(scratch.contains { $0.hasPrefix("sep-") },
                       "the separator's scratch must be cleaned up: \(scratch)")
    }

    func testImportEngineOmitsInstrumentalForAcapella() async throws {
        let dir = tempDir("acapella")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = dir.appendingPathComponent("library", isDirectory: true)

        let engine = SongBundleImportEngine(
            libraryRoot: library,
            separator: fakeSeparator(scratch: dir, instrumentalRMS: nil)) // silent instrumental
        let outcome = try await engine.importSong(source: fixture("mix44k_short.wav"),
                                                  title: "Acapella")

        XCTAssertFalse(outcome.manifest.hasInstrumental)
        XCTAssertFalse(outcome.manifest.parts.contains { $0.part == .instrumental })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outcome.bundleURL.appendingPathComponent("stems/INSTRUMENTAL.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outcome.bundleURL.appendingPathComponent("stems/VOCALS.m4a").path))
        let validation = BundleValidator.validate(bundleDirectory: outcome.bundleURL)
        XCTAssertTrue(validation.isValid, "violations: \(validation.violations)")
    }

    func testFailedImportPublishesNothingAndLeavesNoBundleID() async throws {
        let dir = tempDir("failure")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = dir.appendingPathComponent("library", isDirectory: true)

        struct Boom: Error {}
        let engine = SongBundleImportEngine(libraryRoot: library, separator: { _, _ in
            throw Boom()
        })
        do {
            _ = try await engine.importSong(source: fixture("mix44k_short.wav"), title: "Fails")
            XCTFail("the failing separation must propagate")
        } catch {
            XCTAssertTrue(error is Boom)
        }
        // C-9 rule 1: a failed import leaves the id nil and publishes nothing.
        XCTAssertNil(engine.importedBundleID)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "no bundle and no staging dir may survive: \(leftovers)")
    }
}
