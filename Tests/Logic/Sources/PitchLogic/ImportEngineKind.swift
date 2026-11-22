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
