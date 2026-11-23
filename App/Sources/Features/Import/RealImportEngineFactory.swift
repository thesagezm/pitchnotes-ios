import Foundation
import EngineCore
import PitchLogic

// RealImportEngineFactory (J-208) — the REAL half of the import seam.
//
// THE COMPILE GUARD IS THE POINT (the J-105 precedent, one step further).
// The binding needs BOTH:
//   · `canImport(ImportKit)` — the SPM package that carries Paul's P-204
//     engine (`SongBundleImportEngine`). FALSE on any branch that does not
//     carry `Engine/ImportKit` (main before the gate merge), TRUE once
//     paul→main lands it AND Leto's project.yml wires the package into the
//     app target (X-209 §1);
//   · `canImport(DemucsShim)` — the vendored demucs.cpp bridge, which is an
//     APP-TARGET source (`Engine/Separation/DemucsEngine.swift`). The app
//     INJECTS the separator, so the app must be able to see `DemucsEngine`;
//   · `SEPARATION_IMPORT_ENGINE` — the custom compilation condition Leto adds
//     at gate step 5 (X-209 §1c). It is the deliberate switch: FALSE until
//     the real path is meant to be live.
//
// So THIS FILE COMPILES ON EVERY WORLD: before the merge the block is skipped
// and the app runs the mock (loudly labelled); after the merge AND after the
// real engine lands, the real engine is constructed and the demo runs the
// REAL path (Leto's 21:55Z §1c ruling: the mock path does not satisfy the M2
// gate). No intermediate state can produce a RED build over a class that does
// not exist yet.
//
// THE ENGINE'S ACTUAL SURFACE (session 7 — this replaced the X-208 spec,
// which described a surface Paul did not build):
//
//   public final class SongBundleImportEngine: ProgressReportingEngine,
//       BundleProducingEngine, @unchecked Sendable {
//     public init(libraryRoot: URL, separator: ImportOrchestrator.SeparationRun)
//     public var importedBundleID: String? { get }
//     public func importSong(source: URL, title: String) async throws -> ImportOutcome
//   }
//
// Three consequences the binding has to honour:
//
//   1. THE MODEL PATH IS NOT AN ENGINE PARAMETER. The engine takes a
//      SEPARATOR; the app owns the weights path (J-207's cache,
//      `<name>-<sha256[:16]>`) and builds `DemucsEngine(modelPath:threads:)`,
//      then injects `demucs.separationRun()`. So the weights never travel
//      through a URLSession in the engine and the engine never touches the
//      network (AGENTS §0).
//   2. THE PUBLISH IS ATOMIC AND THE ENDR ENTRY POINT IS `importSong`. The
//      real engine's `separate(audio,mode:)` returns raw stem URLs and
//      publishes NOTHING — so the app MUST drive `importSong` for this
//      engine. `importSong` owns decode → separate → assemble → atomic
//      publish (C-2.2) and returns the `ImportOutcome` (bundle id + the
//      manifest), which is translated into the app-side `PublishedImport`.
//   3. THE OUTCOME IS TRANSLATED, NOT ASSUMED. `ImportOutcome` is
//      EngineCore's type and the contract clause that names `importSong` is
//      still in flight (X-209 §2). The app translates it into the app-side
//      `PublishedImport` at this one seam point, so a contract rename is a
//      one-place change in MY lane.
//
// The app owns the weights path (J-207's cache, `<name>-<sha256[:16]>`), so
// the engine receives a path and never touches the network (AGENTS §0).

#if canImport(ImportKit) && canImport(DemucsShim) && SEPARATION_IMPORT_ENGINE

import ImportKit

/// Builds the real separation engine.
///
/// When the real engine is compiled in but its weights are missing, the
/// factory THROWS with an actionable message instead of falling back to the
/// mock: a silent mock would let a mock demo pass as a real one (D-12).
struct RealImportEngineFactory: ImportEngineFactory {

    let modelURL: URL?

    init(modelURL: URL?) {
        self.modelURL = modelURL
    }

    func makeEngine(bundleRoot: URL) throws -> ImportEngineHandle {
        guard let modelURL else {
            throw ImportError.separationUnavailable(
                "The separation model (htdemucs, 84 MB) is not on this device yet. Download it in Settings → Models, then import again.")
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw ImportError.separationUnavailable(
                "The separation model file is missing from the app's cache. Download it again in Settings → Models.")
        }
        // The app owns the weights path; the engine owns the separation.
        //
        // `DemucsEngine.init` does NOT throw — the weights are loaded LAZILY
        // (Paul's `loadModelIfNeeded()`), so a corrupt file used to surface
        // MID-SEPARATION as a cryptic engine error, half-way through a long
        // import. The load is done HERE, at the START of the import, so it
        // fails fast with the actionable message (Leto's note on X-212).
        //
        // It runs OFF the main actor: `runImport` is a non-isolated async
        // closure, so the 84 MB dequantize never blocks the UI thread (the
        // factory itself is called from the main actor — putting the load
        // there would freeze the screen for the length of the load).
        let demucs = DemucsEngine(modelPath: modelURL)
        let engine = SongBundleImportEngine(libraryRoot: bundleRoot,
                                             separator: demucs.separationRun())
        return ImportEngineHandle(
            engine: engine,
            kind: .real,
            runImport: { source, title in
                // Fail fast on a bad weights file, BEFORE the long job.
                do {
                    try demucs.loadModelIfNeeded()
                } catch {
                    throw ImportError.separationUnavailable(
                        "The separation model could not be loaded (\(error)). Download it again in Settings → Models.")
                }
                // The ATOMIC call shape: the engine owns decode → separate
                // → assemble → publish. (The frozen C-3 pair is NOT used
                // here — the real engine's `separate` publishes nothing.)
                let outcome = try await engine.importSong(source: source, title: title)
                return PublishedImport(
                    bundleID: outcome.bundleID,
                    duration_s: outcome.manifest.duration_s,
                    stems: Self.publishedStems(in: outcome))
            })
    }

    /// The published stems, read off the manifest the engine wrote.
    ///
    /// The bundle id is authoritative (C-9), so this is only the rule-3
    /// derivation fallback's input — but having it means the fallback works
    /// even if the id is ever unavailable, and the mixer can resolve a stem
    /// without re-reading `song.json`.
    private static func publishedStems(in outcome: ImportOutcome) -> [Part: URL] {
        var stems: [Part: URL] = [:]
        for part in outcome.manifest.parts {
            stems[part.part] = outcome.bundleURL.appendingPathComponent(part.stemFile)
        }
        return stems
    }
}

#endif
