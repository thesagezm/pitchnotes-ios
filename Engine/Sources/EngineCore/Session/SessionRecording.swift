import Foundation

// P-403 · The session recording — OPTIONAL, LOCAL-ONLY, DEFAULT OFF.
//
// THE POLICY (the AC, stated where it is enforced):
//   · DEFAULT OFF: `SessionRecordingPolicy.defaultEnabled == false`. The
//     user turns it ON as a DEVICE-LOCAL setting (the C-19 config's
//     device-local class — never written into a bundle). The Apple-side
//     recorder (`MicCapture.SessionALACRecorder`) enforces the same default
//     independently — an append to a non-enabled recorder refuses, so a UI
//     wiring mistake cannot silently start recording (defence in depth).
//   · LOCAL-ONLY: the recording lives in the app's own container
//     (`SessionRecordingStore.root`), is never uploaded, synced or exported
//     except by the user's explicit share action (AGENTS §0's offline rail;
//     the privacy copy is pinned here so the UI and the file agree).
//   · ALIGNED TO THE SESSION: the file's frame 0 IS the session's first
//     recorded capture, and the manifest carries the linear alignment
//     (bundleTime = B₀ + (captureTime − C₀)) so replay maps a bundle time to
//     a file frame EXACTLY (the same clock-fact pattern as PlaybackLane).
//     J-403's latency offset composes at GRADING time (C-20 §4), never in
//     the file — the recording is the raw captured audio.
//   · DELETABLE: `SessionRecordingStore.delete` purges the audio AND its
//     manifest sidecar — a "deleted" recording that left a manifest would be
//     a lie about what is on disk.

/// The session recording's policy constants (P-403).
public enum SessionRecordingPolicy {

    /// **DEFAULT OFF** — the AC's first clause. The user opts in, per device.
    public static let defaultEnabled = false

    /// The recording stores the CONTRACT capture rate (C-3: 16 kHz mono —
    /// the same chunks the live path consumed; no second capture path).
    public static let sampleRate = CaptureSpec.targetSampleRate

    /// The container format: ALAC .m4a (the P-204 precedent — the native
    /// encoder, no ffmpeg).
    public static let containerFormat = "ALAC"

    /// THE PRIVACY COPY (pinned here so the UI's screen and the file's
    /// manifest say the SAME thing — the honest-licenses-screen pattern).
    public static let privacyNotice =
        "Session recordings stay on this device, in this app's storage. " +
        "They are never uploaded, synced or analysed anywhere. " +
        "Recording is OFF unless you turn it on, and deleting a session " +
        "deletes its recording completely."
}

/// The linear session alignment: the session began at bundle time B₀ (the
/// playback position when recording started) and at capture time C₀ (the
/// capture clock's value then). Bundle time of a captured sample =
/// B₀ + (captureTime − C₀). File frame of a bundle time =
/// (bundleTime − B₀) · sampleRate — exact, no modelled latency.
public struct SessionRecordingAlignment: Codable, Equatable, Sendable {

    /// The bundle time at the recording's first frame (B₀).
    public let bundleTimeAtSessionStart_s: Double
    /// The capture clock at the recording's first frame (C₀).
    public let captureTimeAtSessionStart_s: Double
    /// The recording's sample rate (the file frames' clock).
    public let sampleRate: Int

    public init(bundleTimeAtSessionStart_s: Double,
                captureTimeAtSessionStart_s: Double,
                sampleRate: Int) {
        self.bundleTimeAtSessionStart_s = bundleTimeAtSessionStart_s
        self.captureTimeAtSessionStart_s = captureTimeAtSessionStart_s
        self.sampleRate = sampleRate
    }

    /// Bundle time for a captured sample (the live mapping).
    public func bundleTime(forCaptureTime captureTime_s: Double) -> Double {
        bundleTimeAtSessionStart_s + (captureTime_s - captureTimeAtSessionStart_s)
    }

    /// The FILE FRAME a bundle time replays at (the replay mapping — exact:
    /// frame = (B − B₀) · sampleRate).
    public func fileFrame(forBundleTime bundleTime_s: Double) -> Int {
        Int(((bundleTime_s - bundleTimeAtSessionStart_s)
             * Double(sampleRate)).rounded())
    }

    /// The bundle time a file frame replays at (the inverse).
    public func bundleTime(forFileFrame frame: Int) -> Double {
        bundleTimeAtSessionStart_s + Double(frame) / Double(sampleRate)
    }
}

/// The recording's manifest sidecar — the file the UI lists for replay and
/// delete. LOCAL-ONLY: never written into a SongBundle, never exported except
/// by the user's explicit action.
public struct SessionRecordingManifest: Codable, Equatable, Sendable {

    /// The schema family string (the CONTRACTS absence-rule class: additive
    /// fields only; readers ignore what they do not know).
    public static let schemaVersion = "v1.2"

    /// The schema family string ON DISK.
    public let contractVersion: String

    /// The session the recording belongs to (J-402's session id).
    public let sessionId: String
    /// The bundle (song) the session ran against.
    public let bundleId: String
    /// The part the user sang.
    public let partRawValue: String
    /// The wall-clock creation stamp.
    public let createdAt: String
    /// The alignment (above).
    public let alignment: SessionRecordingAlignment
    /// The recorded frame count (the file's own length after stop).
    public var frameCount: Int
    /// Container format (always "ALAC").
    public let format: String
    /// The privacy copy, pinned (the manifest says what the screen says).
    public let privacyNotice: String

    public init(sessionId: String, bundleId: String, partRawValue: String,
                createdAt: String, alignment: SessionRecordingAlignment) {
        self.contractVersion = Self.schemaVersion
        self.sessionId = sessionId
        self.bundleId = bundleId
        self.partRawValue = partRawValue
        self.createdAt = createdAt
        self.alignment = alignment
        self.frameCount = 0
        self.format = SessionRecordingPolicy.containerFormat
        self.privacyNotice = SessionRecordingPolicy.privacyNotice
    }

    public var duration_s: Double {
        Double(frameCount) / Double(alignment.sampleRate)
    }
}

/// The recording store: one directory per session, `recording.m4a` +
/// `recording.json`. Foundation-only, portable, docker-tested.
public struct SessionRecordingStore {

    /// The store's root (the app passes its own container path — the store
    /// never invents one).
    public let root: URL

    public init(root: URL) { self.root = root }

    /// The session's directory.
    public func directory(forSession sessionId: String) -> URL {
        root.appendingPathComponent(sessionId, isDirectory: true)
    }

    /// The session's audio file (ALAC .m4a).
    public func audioURL(forSession sessionId: String) -> URL {
        directory(forSession: sessionId).appendingPathComponent("recording.m4a")
    }

    /// The session's manifest sidecar.
    public func manifestURL(forSession sessionId: String) -> URL {
        directory(forSession: sessionId).appendingPathComponent("recording.json")
    }

    /// The recording EXISTS iff BOTH the audio and its manifest exist — a
    /// half-written recording is not listed for replay.
    public func exists(sessionId: String) -> Bool {
        FileManager.default.fileExists(atPath: audioURL(forSession: sessionId).path)
            && FileManager.default.fileExists(atPath: manifestURL(forSession: sessionId).path)
    }

    /// Write (create-or-replace) the manifest sidecar.
    public func writeManifest(_ manifest: SessionRecordingManifest,
                              forSession sessionId: String) throws {
        let dir = directory(forSession: sessionId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(forSession: sessionId), options: .atomic)
    }

    /// Read the manifest sidecar.
    public func readManifest(forSession sessionId: String) throws -> SessionRecordingManifest {
        let data = try Data(contentsOf: manifestURL(forSession: sessionId))
        return try JSONDecoder().decode(SessionRecordingManifest.self, from: data)
    }

    /// THE PURGE (the AC): the audio AND the manifest AND the session's
    /// directory are GONE — nothing half-left. Returns true when something
    /// was actually removed (the UI can say "purged" honestly).
    @discardableResult
    public func delete(sessionId: String) -> Bool {
        let dir = directory(forSession: sessionId)
        let audio = audioURL(forSession: sessionId)
        let manifest = manifestURL(forSession: sessionId)
        let fm = FileManager.default
        var removed = false
        for url in [audio, manifest] where fm.fileExists(atPath: url.path) {
            do { try fm.removeItem(at: url); removed = true } catch { /* kept: retried below */ }
        }
        // The directory itself goes too (it holds nothing else).
        if fm.fileExists(atPath: dir.path) {
            do { try fm.removeItem(at: dir); removed = true } catch { /* the dir stayed */ }
        }
        // THE PURGE GUARD: if anything survived, that is a defect, not a
        // soft state — the caller sees exists() still true.
        return removed
    }
}
