import Foundation
import EngineCore

// ImportFlowRules (J-201) — the pure decision layer for the import flow's
// error states, disk budget, and thermal notices (UX §5.1 failure states;
// AGENTS §8). All user-facing copy lives HERE so the wording is unit-tested;
// views only render it.

/// User-facing import failure categories. `.cancelled` is not an error in the
/// UI (the flow resets to idle — C-8 cancellation contract) but is part of the
/// mapping so callers handle every outcome exhaustively.
public enum ImportError: Error, Equatable, Sendable {
    case unsupportedFile(String)
    case permissionDenied
    case diskFull(neededBytes: Int64, availableBytes: Int64)
    case decodeFailed(String)
    case engineFailure(String)
    /// The SEPARATION MODEL is not usable for this import — it was never
    /// downloaded, the cached file is corrupt, or the weights could not be
    /// loaded. The app owns the download (J-207), so this case always carries
    /// the instruction that actually fixes it.
    ///
    /// It exists as its OWN case (not `.engineFailure`) because the advice
    /// differs: "download the model" is the fix here, while "retry" is the
    /// fix for a transient engine failure. Telling a human to retry a missing
    /// 84 MB download is exactly the wrong advice at the demo (UX §10.2
    /// step 0 — the human checks the model state BEFORE importing).
    case separationUnavailable(String)
    /// THIS BUILD cannot do a real separation (the real engine is not
    /// compiled in). The user cannot fix this by retrying or downloading —
    /// it needs a build with the real engine, so it gets its own advice too.
    case engineUnavailable(String)
    case cancelled
    case unknown(String)

    /// Title + recovery suggestion (UX §5.1 failure copy; tone = honest,
    /// actionable, never blames the user's file without cause).
    public var title: String {
        switch self {
        case .unsupportedFile: return "Unsupported file"
        case .permissionDenied: return "File access denied"
        case .diskFull: return "Not enough storage"
        case .decodeFailed: return "Couldn't read the audio"
        case .engineFailure: return "Import failed"
        case .separationUnavailable: return "Separation model unavailable"
        case .engineUnavailable: return "Real separation unavailable"
        case .cancelled: return "Import cancelled"
        case .unknown: return "Import failed"
        }
    }

    public var recoverySuggestion: String {
        switch self {
        case .unsupportedFile: return "PitchNotes imports MP3, FLAC, WAV and M4A (ALAC) files."
        case .permissionDenied: return "Re-pick the file from the Files browser so PitchNotes can read it."
        case .diskFull: return "Free up space (Settings → Storage shows per-song usage) and try again."
        case .decodeFailed: return "The file may be corrupt or an unusual codec. Try exporting it as WAV or FLAC."
        case .engineFailure: return "Something went wrong while processing. Retrying usually helps; nothing partial was saved."
        case .separationUnavailable: return "Download the separation model in Settings → Models, then import again. Nothing partial was saved."
        case .engineUnavailable: return "This build of PitchNotes cannot separate audio for real. Use a build with the real separation engine — a demo (mock) build cannot make a real import."
        case .cancelled: return "No partial import was saved."
        case .unknown: return "Nothing partial was saved. Retrying usually helps."
        }
    }

    /// The SPECIFIC reason, rendered under the title (nil when the title and
    /// the recovery line already say everything).
    ///
    /// WHY THIS EXISTS (session 8): the app has always written ACTIONABLE
    /// messages into the error cases ("The separation model (htdemucs, 84 MB)
    /// is not on this device yet. Download it in Settings → Models…"), but
    /// the failure screen rendered only the title and the recovery line —
    /// so the reason never reached the human. The copy was written for the
    /// screen and the screen dropped it.
    public var detail: String? {
        switch self {
        case .unsupportedFile(let msg): return msg
        case .permissionDenied: return "PitchNotes could not open the selected file."
        case .diskFull(let needed, let available):
            // UX §5.1: the disk-full state shows needed-vs-available bytes.
            return "This import needs about \(ImportByteFormat.megabytes(needed)) of free space; this iPhone has \(ImportByteFormat.megabytes(available)) free."
        case .decodeFailed(let msg): return msg
        case .engineFailure(let msg): return msg
        case .separationUnavailable(let msg): return msg
        case .engineUnavailable(let msg): return msg
        case .cancelled: return nil
        case .unknown(let msg): return msg
        }
    }
}

/// Byte formatting for the user-facing copy (the disk-full state).
public enum ImportByteFormat {
    /// A megabyte with one decimal — the unit the human can act on (the raw
    /// byte count is a developer's number).
    public static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}

/// Maps thrown errors onto the user-facing categories (C-8 cancellation
/// contract: CancellationError → .cancelled; engines may NOT wrap a pure
/// cancellation in EngineError — C-8 — so this mapping is exhaustive-safe).
public enum ImportFailure {
    public static func cause(from error: Error) -> ImportError {
        if error is CancellationError { return .cancelled }
        switch error {
        case EngineError.unsupportedFormat(let msg): return .unsupportedFile(msg)
        case EngineError.importFailed(let msg): return .decodeFailed(msg)
        case EngineError.modelMissing:
            // The ENGINE could not load the weights. The raw engine text
            // ("demucs ggml load failed (status …)") is a developer's number;
            // the human's next step is the same in every case — download the
            // model again (J-207 owns the download) — so the app says THAT.
            return .separationUnavailable(
                "The separation model could not be loaded. Download it again in Settings → Models.")
        case EngineError.separationFailed(let msg),
             EngineError.contractViolation(let msg):
            return .engineFailure(msg)
        default: break
        }
        let ns = error as NSError
        // Disk full: POSIX ENOSPC (28) arrives via POSIXError/Cocoa wrappers.
        if ns.code == 28,
           ns.domain == NSPOSIXErrorDomain || ns.domain == NSCocoaErrorDomain {
            return .diskFull(neededBytes: 0, availableBytes: 0)
        }
        // Permission: Cocoa file read/write no-permission, or URL error class.
        // NSCocoaErrorDomain 257 = NSFileReadNoPermissionDenied,
        // 513 = NSFileWriteNoPermissionDenied (literal codes — the named
        // constants are not in scope in this SPM target on CI).
        if ns.domain == NSCocoaErrorDomain,
           ns.code == 257 || ns.code == 513 {
            return .permissionDenied
        }
        if let urlError = error as? URLError,
           urlError.code == .noPermissionsToReadFile {
            return .permissionDenied
        }
        return .unknown(String(describing: error))
    }
}

// MARK: - Disk budget (pre-flight check before any engine work)

/// Import writes a decoded mix + stems; the pre-flight refuses to start when
/// the volume clearly cannot hold the result (J-201 error state: disk full —
/// checked BEFORE the long job, not at first write failure).
public enum ImportDiskBudget {
    /// Policy multiplier: decoded 44.1 kHz mix (≈ compressed source size for
    /// MP3/FLAC, ≈ source for WAV) + two ALAC stems + assembly margin. Three
    /// source sizes is honest headroom without over-refusing; documented here
    /// so changes are deliberate.
    public static let safetyMultiplier: Double = 3.0

    public enum Verdict: Equatable, Sendable {
        case ok
        case short(neededBytes: Int64, availableBytes: Int64)
    }

    public static func requiredBytes(sourceBytes: Int64) -> Int64 {
        Int64((Double(max(sourceBytes, 0)) * safetyMultiplier).rounded())
    }

    public static func verdict(sourceBytes: Int64, availableBytes: Int64) -> Verdict {
        let needed = requiredBytes(sourceBytes: sourceBytes)
        return availableBytes >= needed
            ? .ok
            : .short(neededBytes: needed, availableBytes: max(availableBytes, 0))
    }
}

// MARK: - Thermal gate (AGENTS §8: pace work against ProcessInfo.thermalState)

/// Platform-neutral thermal level — the app bridges
/// `ProcessInfo.thermalState` into this enum (P-202's engine-side pacing uses
/// the same levels; the UI notice here is J-201's half of the contract).
public enum ThermalLevel: Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

public enum ImportThermalGate {
    public enum Advice: Equatable, Sendable {
        case none
        /// Device is warm: show a notice; the engine paces itself (longer
        /// chunk sleeps) — the import continues.
        case slowDown(String)
        /// Device is hot: recommend deferring to the charging quality mode
        /// (BGProcessingTask, AGENTS §8) but the user may proceed.
        case deferRecommended(String)

        public var message: String? {
            switch self {
            case .none: return nil
            case .slowDown(let m), .deferRecommended(let m): return m
            }
        }
    }

    public static let seriousCopy =
        "The device is running warm. The import continues at a gentler pace to protect battery and thermals."
    public static let criticalCopy =
        "The device is hot. Consider waiting, or run the import later while charging (quality mode)."

    public static func advice(for level: ThermalLevel) -> Advice {
        switch level {
        case .nominal, .fair: return .none
        case .serious: return .slowDown(seriousCopy)
        case .critical: return .deferRecommended(criticalCopy)
        }
    }
}
