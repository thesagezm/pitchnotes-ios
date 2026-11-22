import Foundation

// ImportEngineKind (J-208) — WHICH engine an import ran on.
//
// This is a PURE type in the shared package so the honest wording is
// unit-tested (the strings are what stops a mock demo from being mistaken
// for a real separation — D-12 honesty; Leto 21:55Z §1c: the M2 gate is
// RULED to require the real path, a scripted mock demo would be a D-12
// honesty failure at the gate).
public enum ImportEngineKind: Equatable, Sendable {
    /// The scripted mock (ScriptedImportEngine) — UI regression only.
    case mock
    /// The real separation engine (htdemucs).
    case real

    public var isReal: Bool { self == .real }

    /// One-line, honest status for the import screen.
    public var statusLine: String {
        switch self {
        case .mock:
            return "DEMO ENGINE (mock) — no real separation was run."
        case .real:
            return "Real engine (htdemucs fp16)."
        }
    }
}

/// What the app can do BEFORE an import starts (J-208, session 6).
///
/// The `ImportEngineKind` badge answers "which engine ran?" — but the demo
/// script (UX §10.2 step 0) asks the human to check the badge BEFORE the
/// import ("the badge must read 'Real engine'"), right after downloading the
/// model. Without this type the pre-import badge was the mock line, so the
/// human would read "DEMO ENGINE (mock)" on a build that is perfectly capable
/// of the real path — a false negative on the one screen the demo reads first.
///
/// The four states are exactly the four combinations of (the real engine is
/// compiled in) × (the weights are on the device), because the app's resolver
/// (D-12 honesty) does NOT silently fall back to the mock in the
/// compiled-in-but-no-weights and not-compiled-in-but-weights-on-device cases.
public enum ImportEngineAvailability: Equatable, Sendable {
    /// The real engine is compiled in AND its weights are on the device.
    case realReady
    /// The real engine is compiled in, but the weights are not downloaded yet.
    case realModelMissing
    /// No real engine in this build and no weights on the device — the mock
    /// runs (and says so).
    case mockOnly
    /// No real engine in this build, but the weights ARE on the device: the
    /// import FAILS with that reason instead of quietly running the mock.
    case realUnavailable

    /// The pure rule — the one place the mapping lives.
    public static func resolve(compiledIn: Bool, modelPresent: Bool) -> ImportEngineAvailability {
        switch (compiledIn, modelPresent) {
        case (true, true): return .realReady
        case (true, false): return .realModelMissing
        case (false, true): return .realUnavailable
        case (false, false): return .mockOnly
        }
    }

    /// Whether the REAL path is available for the next import.
    public var isReal: Bool {
        switch self {
        case .realReady, .realModelMissing: return true
        case .mockOnly, .realUnavailable: return false
        }
    }

    /// One-line, honest status for the import screen BEFORE an import runs.
    public var statusLine: String {
        switch self {
        case .realReady:
            return "Real engine (htdemucs fp16) — ready."
        case .realModelMissing:
            return "Real engine (htdemucs fp16) — the model is not on this device yet (Settings → Models)."
        case .mockOnly:
            return "DEMO ENGINE (mock) — no real separation was run."
        case .realUnavailable:
            return "Real separation is not in this build, and the model is already on this device — an import will fail rather than quietly run the mock."
        }
    }
}
