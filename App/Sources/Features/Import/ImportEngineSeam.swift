import Foundation
import EngineCore
import PitchLogic

// ImportEngineSeam (J-208) — THE swap seam for the M2 import flow.
//
// Why this exists (D-34 GAP 1, Leto 2026-11-22T21:30Z): `ImportModel.beginImport()`
// hard-wired `ScriptedImportEngine` (Jess's own mock), so "import a real SDA
// FLAC → stems → mixer" was impossible — there was no path from the app to
// the real separation engine at all. The M2 gate is RULED to require the real
// path (Leto 21:55Z §1c): a scripted mock demo would be a D-12 honesty failure.
//
// Shape of the seam (the J-105 precedent: a seam is not a UI change):
//   · `ImportEngineFactory` produces the engine for one import.
//   · `ImportEngineHandle` = the engine + how to ask "which bundle did this
//     publish?" (C-9 `importedBundleID`, preferred) — the C-9 rule-3
//     derivation lives in `BundleIdentityResolver` and is used as the fallback.
//   · The MOCK stays the default for previews/tests; the REAL engine is
//     constructed by `RealImportEngineFactory` (guarded by `#if canImport(
//     DemucsShim)` — FALSE before the paul→main merge, TRUE after it).
//   · Every import states WHICH engine ran (`ImportEngineKind`), so a mock
//     demo can never be mistaken for a real separation (D-12 honesty).
//
// ZERO view changes are needed to swap the engine: the views read the model.

// MARK: - The seam

/// Produces the engine for one import. One seam, two implementations
/// (mock + real) — the app never names a concrete engine at the call site.
/// (`ImportEngineKind` — which engine ran — is the pure type in PitchLogic,
/// so its honest wording is unit-tested.)
protocol ImportEngineFactory {
    /// - Parameter bundleRoot: the library root the engine assembles into.
    func makeEngine(bundleRoot: URL) throws -> ImportEngineHandle
}

/// The engine plus the C-9 fact carrier.
struct ImportEngineHandle: Sendable {
    /// The engine itself (C-8 progress reporting + C-3 EngineAPI).
    let engine: any ProgressReportingEngine
    /// C-9 `importedBundleID` — nil until the bundle is PUBLISHED (C-9 rule 1:
    /// set only after the atomic rename; nil on cancel/failure).
    let bundleID: @Sendable () -> String?
    /// Which engine this is (for the honest status line).
    let kind: ImportEngineKind
}

/// The C-9 producer, as seen by the app. ScriptedImportEngine already exposes
/// `importedBundleID`; the real engine conforms to EngineCore's C-9 protocol
/// after the paul→main merge (see `RealImportEngineFactory`).
protocol BundleIDReporting {
    var importedBundleID: String? { get }
}

// MARK: - Mock factory (previews, tests, UI regression)

/// The M2 mock: `ScriptedImportEngine` (J-201). Kept as the default so the
/// flow UI, progress enforcement, cancellation and C-2.2 atomic semantics stay
/// exercisable without the 84 MB weights.
struct MockImportEngineFactory: ImportEngineFactory {
    var scenario: MockScenario = .perfect
    var seed: UInt64 = 0x2011

    func makeEngine(bundleRoot: URL) throws -> ImportEngineHandle {
        let engine = ScriptedImportEngine(bundleRoot: bundleRoot, scenario: scenario, seed: seed)
        return ImportEngineHandle(
            engine: engine,
            bundleID: { engine.importedBundleID },
            kind: .mock)
    }
}

// MARK: - Resolver (which engine runs)

/// Whether THIS BUILD contains the real separation engine (compile-time fact).
///
/// The same guard the resolver uses, expressed as a value so the import
/// screen can say BEFORE an import starts what the next import will do
/// (UX §10.2 step 0: the human reads the badge to confirm the real path is
/// armed — a badge that only appears after the import is useless for that
/// check).
enum RealEngineBuild {
    /// TRUE when the real separation engine is compiled into this build.
    static var isCompiledIn: Bool {
        #if canImport(DemucsShim) && SEPARATION_IMPORT_ENGINE
        return true
        #else
        return false
        #endif
    }
}

/// Chooses the engine for an import.
///
/// THE HONEST RULE (D-34 GAP 1 + Leto 21:55Z §1c): the mock path does NOT
/// satisfy the M2 gate, so the app must not quietly fall back to it. Two
/// worlds, two rules:
///   · the real engine is compiled in (post paul→main) ⇒ it is used, and if
///     its weights are missing the import FAILS with an honest, actionable
///     message (J-207 puts the download in the app) — never a silent mock;
///   · the real engine is NOT compiled in (pre-merge branches) ⇒ the mock
///     runs and the import screen SAYS SO ("DEMO ENGINE (mock)").
/// Previews and tests inject `MockImportEngineFactory` explicitly.
enum ImportEngineResolver {

    /// - Parameter modelURL: the VERIFIED htdemucs ggml path (J-207's cache),
    ///   nil when the weights were never downloaded.
    static func factory(modelURL: URL?) -> ImportEngineFactory {
        #if canImport(DemucsShim) && SEPARATION_IMPORT_ENGINE
        return RealImportEngineFactory(modelURL: modelURL)
        #else
        // This build cannot run a real separation. If the weights are ALREADY
        // on the device the user expects a real separation — failing honestly
        // beats silently running the mock (D-12 honesty; the mock path does
        // not satisfy the M2 gate).
        if modelURL != nil {
            return UnavailableRealEngineFactory(
                reason: "this build does not include the real separation engine")
        }
        return MockImportEngineFactory()
        #endif
    }
}

/// The real engine is not compiled into this build (or could not be used):
/// the import FAILS with the reason instead of quietly running the mock.
struct UnavailableRealEngineFactory: ImportEngineFactory {

    let reason: String

    func makeEngine(bundleRoot: URL) throws -> ImportEngineHandle {
        throw ImportError.engineFailure(
            "Real separation is not available: \(reason). A demo import on the mock engine is not a real separation.")
    }
}

// MARK: - C-9 resolution (prefer the protocol, fall back to derivation)

/// Resolves "which bundle did this import publish" (C-9).
enum BundleIdentityResolver {

    /// C-9 rule 2: the consumer MUST prefer `BundleProducingEngine`.
    /// C-9 rule 3: if the engine does not conform, the consumer MAY derive
    /// the bundle dir from the parent of a returned stem URL — but only a
    /// directory that really carries the completion marker (`song.json`,
    /// C-2.2) may be trusted, so a half-written bundle is never registered.
    ///
    /// - Returns: the bundle id, or nil when no complete bundle can be named.
    static func resolveBundleID(
        producerID: String?,
        stems: [Part: URL],
        bundleRoot: URL
    ) -> String? {
        let derivedID = BundleIdentity.candidateBundleID(fromStems: stems)
        let producerComplete = producerID.map {
            isCompleteBundle(at: bundleRoot.appendingPathComponent($0, isDirectory: true))
        } ?? false
        let derivedComplete = derivedID.map {
            isCompleteBundle(at: bundleRoot.appendingPathComponent($0, isDirectory: true))
        } ?? false
        return BundleIdentity.resolve(
            producerID: producerID,
            derivedID: derivedID,
            producerBundleIsComplete: producerComplete,
            derivedBundleIsComplete: derivedComplete)
    }

    /// C-2.2: `song.json` inside the bundle is the completion marker.
    static func isCompleteBundle(at directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("song.json").path)
    }
}
