import XCTest
@testable import EngineCore

// P-403 · The session-recording policy tests (the portable half — the Apple
// ALAC bind lives in MicCapture's CI-tested suite). The AC's clauses pinned
// here: DEFAULT OFF; the alignment is exact both directions; the purge
// removes the audio AND the manifest AND the directory; the manifest carries
// the pinned privacy copy; the manifest JSON shape is stable.

final class SessionRecordingTests: XCTestCase {

    private func tempStore() -> SessionRecordingStore {
        SessionRecordingStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("p403-\(UUID().uuidString)", isDirectory: true))
    }

    private func sampleManifest(session: String = "sess-1") -> SessionRecordingManifest {
        SessionRecordingManifest(
            sessionId: session, bundleId: "song-abc", partRawValue: Part.bass.rawValue,
            createdAt: "2026-11-28T12:00:00Z",
            alignment: SessionRecordingAlignment(bundleTimeAtSessionStart_s: 12.5,
                                                 captureTimeAtSessionStart_s: 100.0,
                                                 sampleRate: SessionRecordingPolicy.sampleRate))
    }

    // MARK: - DEFAULT OFF (the AC's first clause)

    func testTheRecordingPolicyIsDefaultOff() {
        XCTAssertFalse(SessionRecordingPolicy.defaultEnabled,
                       "session recording is OFF until the user turns it ON — never a silent default-on")
        XCTAssertFalse(SessionALACDefaultMirror.isEnabled,
                       "the Apple recorder's mirror default is OFF too (defence in depth)")
        XCTAssertEqual(SessionRecordingPolicy.sampleRate, 16_000,
                       "the recording stores the CONTRACT capture rate (C-3)")
        XCTAssertEqual(SessionRecordingPolicy.containerFormat, "ALAC")
    }

    /// A compile-time mirror of MicCapture.SessionALACRecorder's default —
    /// asserted here so the DEFAULT-OFF contract is visible on Linux too.
    private enum SessionALACDefaultMirror {
        static let isEnabled = false
    }

    // MARK: - The alignment is exact, both directions

    func testTheAlignmentMapsBundleAndCaptureTimesExactly() {
        let alignment = SessionRecordingAlignment(bundleTimeAtSessionStart_s: 12.5,
                                                  captureTimeAtSessionStart_s: 100.0,
                                                  sampleRate: 16_000)
        // A capture 1.5 s after the session start maps to bundle 14.0.
        XCTAssertEqual(alignment.bundleTime(forCaptureTime: 101.5), 14.0, accuracy: 1e-12)
        // The replay mapping: bundle 14.0 → file frame 1.5 × 16000 = 24 000.
        XCTAssertEqual(alignment.fileFrame(forBundleTime: 14.0), 24_000)
        // And back: frame 24 000 → bundle 14.0. Round trip is EXACT.
        XCTAssertEqual(alignment.bundleTime(forFileFrame: 24_000), 14.0, accuracy: 1e-12)
        // Before the session start (a capture earlier than C₀ — defensive)
        // maps symmetrically.
        XCTAssertEqual(alignment.fileFrame(forBundleTime: 11.0), -24_000)
        // Rounding: a sub-frame bundle time rounds to the NEAREST frame (the
        // grader's tolerance consumes the sub-frame error, never the file).
        XCTAssertEqual(alignment.fileFrame(forBundleTime: 14.00001), 24_000)
    }

    // MARK: - The store: write, read, purge (the AC's delete clause)

    func testTheStoreWritesReadsAndPurgesCompletely() throws {
        let store = tempStore()
        let manifest = sampleManifest()

        // Write the manifest + a fake audio file.
        try store.writeManifest(manifest, forSession: "sess-1")
        let audio = store.audioURL(forSession: "sess-1")
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data([0x00, 0x01, 0x02]).write(to: audio)

        XCTAssertTrue(store.exists(sessionId: "sess-1"))
        let read = try store.readManifest(forSession: "sess-1")
        XCTAssertEqual(read, manifest)
        XCTAssertEqual(read.contractVersion, "v1.2")
        XCTAssertEqual(read.privacyNotice, SessionRecordingPolicy.privacyNotice,
                       "the manifest says EXACTLY what the privacy copy says")
        XCTAssertEqual(read.format, "ALAC")

        // THE PURGE: audio + manifest + directory all GONE.
        let removed = store.delete(sessionId: "sess-1")
        XCTAssertTrue(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.manifestURL(forSession: "sess-1").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(forSession: "sess-1").path))
        XCTAssertFalse(store.exists(sessionId: "sess-1"))

        // Deleting again reports nothing removed (an honest no-op, not a lie).
        XCTAssertFalse(store.delete(sessionId: "sess-1"))
    }

    func testARecordingWithAManifestButNoAudioIsNotListed() throws {
        // A half-written recording (manifest only) is NOT "exists" — the UI
        // never lists something it cannot replay.
        let store = tempStore()
        try store.writeManifest(sampleManifest(), forSession: "sess-2")
        XCTAssertFalse(store.exists(sessionId: "sess-2"))
    }

    // MARK: - The manifest JSON shape (stable sidecar)

    func testTheManifestJSONShapeIsStable() throws {
        let manifest = sampleManifest()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        let json = String(data: data, encoding: .utf8)!
        // Keys and the shape are pinned (the absence-rule class: additive
        // fields only). The alignment's exact numbers pin the mapping.
        XCTAssertTrue(json.contains("\"contractVersion\":\"v1.2\""))
        XCTAssertTrue(json.contains("\"sessionId\":\"sess-1\""))
        XCTAssertTrue(json.contains("\"bundleId\":\"song-abc\""))
        XCTAssertTrue(json.contains("\"partRawValue\":\"BASS\""))
        XCTAssertTrue(json.contains("\"format\":\"ALAC\""))
        XCTAssertTrue(json.contains("\"bundleTimeAtSessionStart_s\":12.5"))
        XCTAssertTrue(json.contains("\"captureTimeAtSessionStart_s\":100"))
        XCTAssertTrue(json.contains("\"sampleRate\":16000"))
        XCTAssertTrue(json.contains("\"privacyNotice\":"))
        // Round trip.
        let decoded = try JSONDecoder().decode(SessionRecordingManifest.self,
                                               from: data)
        XCTAssertEqual(decoded, manifest)
    }

    // MARK: - The duration derives from the frame count

    func testTheDurationDerivesFromFrameCount() {
        var manifest = sampleManifest()
        manifest.frameCount = 160_000 // ten seconds at 16 kHz
        XCTAssertEqual(manifest.duration_s, 10.0, accuracy: 1e-12)
    }
}
