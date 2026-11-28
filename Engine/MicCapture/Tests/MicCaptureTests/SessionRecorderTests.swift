import XCTest
import AVFoundation
@testable import MicCapture
import EngineCore

// SessionALACRecorder tests (P-403, PAUL lane — macOS CI; the package is
// Apple-only). NO mic, NO capture session: the recorder consumes plain
// chunks, so the tests exercise (1) THE DEFAULT-OFF GUARD at the writer
// itself (an append without the user's opt-in refuses — defence in depth
// beside EngineCore's policy default), (2) the REAL ALAC encode on the
// runner (the P-204 precedent: AVAudioFile's ALAC encoder works headless —
// write, stop, read back, assert frames + duration), (3) the sample-rate
// contract (a non-16k chunk is refused, never silently resampled here — the
// capture pipeline owns resampling), and (4) the manifest handoff with the
// final frame count.

final class SessionRecorderTests: XCTestCase {

    private func sineChunk(frames: Int, rate: Int = 16_000) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        let twoPiF = 2.0 * Double.pi * 220.0
        for index in 0..<frames {
            let phase = twoPiF * Double(index) / Double(rate)
            out[index] = Float(0.4 * sin(phase))
        }
        return out
    }

    private func manifest() -> SessionRecordingManifest {
        SessionRecordingManifest(
            sessionId: "sess-test", bundleId: "song-abc", partRawValue: "BASS",
            createdAt: "2026-11-28T12:00:00Z",
            alignment: SessionRecordingAlignment(bundleTimeAtSessionStart_s: 8.0,
                                                 captureTimeAtSessionStart_s: 0.0,
                                                 sampleRate: SessionRecordingPolicy.sampleRate))
    }

    // MARK: - (1) The default-off guard AT THE WRITER

    func testTheRecorderIsDisabledByDefaultAndRefusesAppends() throws {
        let recorder = SessionALACRecorder()
        XCTAssertFalse(recorder.isEnabled,
                       "DEFAULT OFF — the AC's first clause, enforced at the writer too")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("p403-guard-\(UUID().uuidString).m4a")
        // start() refuses while disabled.
        XCTAssertThrowsError(try recorder.start(url: url, manifest: manifest())) { error in
            XCTAssertEqual(error as? SessionALACRecorder.RecorderError, .recordingDisabled)
        }
        // append() refuses while disabled — a UI wiring mistake cannot
        // silently start recording.
        XCTAssertThrowsError(try recorder.append(sineChunk(frames: 1024), sampleRate: 16_000)) { error in
            XCTAssertEqual(error as? SessionALACRecorder.RecorderError, .recordingDisabled)
        }
        // And NO file was created by the refused start (nothing half-open).
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "a refused start must not leave a file on disk")
    }

    // MARK: - (2) The REAL ALAC encode, read back (the P-204 precedent)

    func testTheALACWriteRoundTripsThroughTheNativeEncoder() throws {
        let recorder = SessionALACRecorder()
        recorder.isEnabled = true // the user's explicit opt-in (device-local)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("p403-alac-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        try recorder.start(url: url, manifest: manifest())
        // Ten 1024-frame chunks = 10 240 frames = 0.64 s at 16 kHz.
        for _ in 0..<10 {
            try recorder.append(sineChunk(frames: 1024), sampleRate: 16_000)
        }
        let finished = try recorder.stop()
        XCTAssertEqual(finished?.frameCount, 10_240)

        // Read the file back through AVAudioFile (the replay path's own
        // decoder): the frame count and duration must match EXACTLY —
        // lossless is the point.
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 10_240)
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 0.64,
                       accuracy: 1e-9)
        // The content survives losslessly (spot-check a mid-buffer sample's
        // energy: a sine's peak is ~0.4).
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                      frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer, frameCount: AVAudioFrameCount(file.length))
        var peak: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            let v = abs(buffer.floatChannelData![0][index])
            if v > peak { peak = v }
        }
        XCTAssertEqual(peak, 0.4, accuracy: 0.02,
                       "the ALAC round trip is lossless (the sine's peak survives)")
    }

    // MARK: - (3) The sample-rate contract

    func testANonContractRateChunkIsRefused() throws {
        let recorder = SessionALACRecorder()
        recorder.isEnabled = true
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("p403-rate-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try recorder.start(url: url, manifest: manifest())
        // 48 kHz raw (device-native) must NOT be appended here — the capture
        // pipeline resamples to 16 kHz; a bypass is a defect, never silently
        // encoded at the wrong clock.
        XCTAssertThrowsError(try recorder.append(sineChunk(frames: 1024, rate: 48_000),
                                                 sampleRate: 48_000)) { error in
            XCTAssertEqual(error as? SessionALACRecorder.RecorderError,
                           .sampleRateMismatch(48_000))
        }
        // The 16 kHz contract rate appends fine.
        XCTAssertNoThrow(try recorder.append(sineChunk(frames: 1024), sampleRate: 16_000))
        try recorder.stop()
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 1_024, "the refused chunk contributed NOTHING")
    }

    // MARK: - (4) The manifest handoff + the store purge (end to end)

    func testTheRecordingFilesFeedTheStoreAndPurgeEndToEnd() throws {
        let store = SessionRecordingStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("p403-store-\(UUID().uuidString)", isDirectory: true))
        let recorder = SessionALACRecorder()
        recorder.isEnabled = true
        let url = store.audioURL(forSession: "sess-e2e")

        let m = manifest()
        try recorder.start(url: url, manifest: m)
        for _ in 0..<5 {
            try recorder.append(sineChunk(frames: 1024), sampleRate: 16_000)
        }
        let finished = try XCTUnwrap(recorder.stop())
        try store.writeManifest(finished, forSession: "sess-e2e")

        XCTAssertTrue(store.exists(sessionId: "sess-e2e"))
        let persisted = try store.readManifest(forSession: "sess-e2e")
        XCTAssertEqual(persisted.frameCount, 5_120)
        XCTAssertEqual(persisted.duration_s, 0.32, accuracy: 1e-12)
        // The replay alignment: bundle time 8.16 s (0.16 s into the session)
        // → file frame 0.16 × 16 000 = 2 560.
        XCTAssertEqual(persisted.alignment.fileFrame(forBundleTime: 8.16), 2_560)

        // The purge (the AC): audio + manifest + directory GONE.
        store.delete(sessionId: "sess-e2e")
        XCTAssertFalse(store.exists(sessionId: "sess-e2e"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
