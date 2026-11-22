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
        case .cancelled: return "No partial import was saved."
        case .unknown: return "Nothing partial was saved. Retrying usually helps."
        }
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
        case EngineError.separationFailed(let msg),
             EngineError.modelMissing(let msg),
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
        if ns.domain == NSCocoaErrorDomain,
           ns.code == NSFileReadNoPermissionDenied || ns.code == NSFileWriteNoPermissionDenied {
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

        var message: String? {
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
