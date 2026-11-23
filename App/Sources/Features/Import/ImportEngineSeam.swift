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
//   · `ImportEngineHandle` = the engine + `runImport`, the ONE call shape the
//     app uses. `runImport` hides whether the engine publishes ATOMICALLY
//     (Paul's P-204 `importSong`) or during the frozen C-3 pair (the mock).
//   · `PublishedImport` carries what was published: the C-9 bundle id
//     (preferred), the source duration and the stems. The C-9 rule-3
//     derivation lives in `BundleIdentityResolver` and is the fallback.
//   · The MOCK stays the default for previews/tests; the REAL engine is
//     constructed by `RealImportEngineFactory` (guarded by `#if canImport(
//     ImportKit) && canImport(DemucsShim) && SEPARATION_IMPORT_ENGINE` — FALSE
//     before the paul→main merge, TRUE after it).
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

/// What an import PUBLISHED — the app-side result, engine-agnostic.
///
/// The app needs three facts after an import: which bundle was published
/// (C-9), how long the separated source was (J-206's RTF denominator), and
/// the stems (the C-9 rule-3 derivation fallback).
///
/// It is deliberately NOT EngineCore's `ImportOutcome`: that type already
/// exists (Paul's P-204 ships it in EngineCore), but the CONTRACT clause
/// that names `importSong` as the entry point is still in flight (X-209's
/// C-9.1), and the app must not be the thing that guesses a contract's
/// shape. The engine's own result is TRANSLATED into this app-side type at
/// the seam, so the app compiles against a shape it owns — and a contract
/// rename later is a one-place change in MY lane, not an app-wide edit.
struct PublishedImport: Sendable {
    /// C-9 `importedBundleID` — the bundle DIRECTORY name, set only after
    /// the atomic publish (C-9 rule 1). nil when the engine published
    /// nothing (never a stale id pointing at staging).
    let bundleID: String?
    /// The duration of the separated source, in seconds. For the mock this is
    /// a size-based ESTIMATE and the UI says so.
    let duration_s: Double
    /// The published stems (for the C-9 rule-3 derivation fallback). May be
    /// empty when the engine reports its bundle id explicitly — the id is
    /// then preferred and the derivation is never needed.
    let stems: [Part: URL]
}

/// The engine plus the way to run an import through it.
struct ImportEngineHandle: Sendable {
    /// The engine itself (C-8 progress reporting + C-3 EngineAPI). The caller
    /// sets the progress handler on THIS object before running the import.
    let engine: any ProgressReportingEngine
    /// Which engine this is (for the honest status line).
    let kind: ImportEngineKind
    /// Runs one import end-to-end and returns what was published.
    ///
    /// TWO CALL SHAPES, and the handle hides which one it is:
    ///   · **atomic** — the engine owns the whole import (decode → separate →
    ///     assemble → atomic publish) and returns the published bundle. This
    ///     is Paul's P-204 engine (`SongBundleImportEngine.importSong`, the
    ///     shape X-209 asks the contract to ratify).
    ///   · **frozen C-3 pair** — the app drives `importAudio` → `separate`,
    ///     and the engine publishes during `separate` (the C-3 semantics the
    ///     mock follows).
    ///
    /// The distinction is NOT cosmetic: the real engine's `separate` returns
    /// raw stem URLs and publishes NOTHING, so an app that drove the C-3 pair
    /// against it would get stems but no bundle — and then fail its own
    /// completeness check with an error that looks like a separation failure.
    let runImport: @Sendable (URL, String) async throws -> PublishedImport
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
            kind: .mock,
            runImport: { source, _ in
                // The frozen C-3 pair — the mock publishes during `separate`.
                let audio = try await engine.importAudio(url: source)
                let stems = try await engine.separate(audio, mode: .twoStem)
                return PublishedImport(
                    bundleID: engine.importedBundleID,
                    duration_s: audio.duration_s,
                    stems: stems)
            })
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
    ///
    /// The guard has THREE parts (session 7), because the real engine needs
    /// three things to be reachable from the app target:
    ///   · `canImport(ImportKit)` — the SPM package carrying Paul's P-204
    ///     engine (`SongBundleImportEngine`);
    ///   · `canImport(DemucsShim)` — the vendored demucs.cpp bridge, because
    ///     the app INJECTS `DemucsEngine` as the engine's separator;
    ///   · `SEPARATION_IMPORT_ENGINE` — Leto's deliberate switch (X-209 §1c).
    static var isCompiledIn: Bool {
        #if canImport(ImportKit) && canImport(DemucsShim) && SEPARATION_IMPORT_ENGINE
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
    ///   nil when the weights are not on the device yet.
    ///
    /// **Call this AT IMPORT TIME, not once at launch** (J-208, session 6): the
    /// weights can arrive after the app started — that IS the demo flow
    /// (Settings → Models → Download → Import). Resolving once at launch froze
    /// the decision: on a real build the import failed with "the model is not
    /// on this device yet" although the human had just downloaded it, and on a
    /// mock-only build the import silently ran the MOCK with the weights
    /// sitting on the device (the exact D-12 failure Leto ruled against).
    ///
    /// The decision itself is the pure, tested truth table in PitchLogic
    /// (`ImportEngineAvailability.resolve`) — this function only maps its four
    /// states onto factories.
    static func factory(modelURL: URL?) -> ImportEngineFactory {
        let availability = ImportEngineAvailability.resolve(
            compiledIn: RealEngineBuild.isCompiledIn,
            modelURL: modelURL)
        switch availability {
        case .realReady, .realModelMissing:
            #if canImport(ImportKit) && canImport(DemucsShim) && SEPARATION_IMPORT_ENGINE
            // The real engine reports a missing model itself, with an
            // actionable message ("download it in Settings → Models").
            return RealImportEngineFactory(modelURL: modelURL)
            #else
            // Unreachable: `realReady`/`realModelMissing` require the engine
            // to be compiled in. Kept total so no future edit can fall
            // through to the mock by accident.
            return UnavailableRealEngineFactory(
                reason: "this build does not include the real separation engine")
            #endif
        case .realUnavailable:
            // The weights ARE on the device but this build cannot separate:
            // failing honestly beats silently running the mock (D-12).
            return UnavailableRealEngineFactory(
                reason: "this build does not include the real separation engine")
        case .mockOnly:
            return MockImportEngineFactory()
        }
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
