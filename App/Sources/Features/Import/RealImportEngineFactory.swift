import Foundation
import EngineCore
import PitchLogic

// RealImportEngineFactory (J-208) — the REAL half of the import seam.
//
// THE COMPILE GUARD IS THE POINT (the J-105 precedent, one step further).
// The binding needs BOTH:
//   · `canImport(DemucsShim)` — FALSE on any branch that does not carry
//     Engine/Separation (main before the gate merge), TRUE once paul→main
//     lands the separation bridge;
//   · `SEPARATION_IMPORT_ENGINE` — the custom compilation condition Leto
//     adds at gate step 5, in the SAME commit that adds Paul's assembled-
//     bundle engine to the app target. It is FALSE until the real engine
//     actually exists.
//
// So THIS FILE COMPILES ON EVERY WORLD: before the merge the block is skipped
// and the app runs the mock (loudly labelled); after the merge AND after the
// real engine lands, the real engine is constructed and the demo runs the
// REAL path (Leto's 21:55Z §1c ruling: the mock path does not satisfy the M2
// gate). No intermediate state can produce a RED build over a class that does
// not exist yet.
//
// The engine is named `SeparationImportEngine` by EXACT SPEC (X-208 in the
// BLOCKED section): Paul owns P-204's assembled-bundle engine and must use
// that name with `init(modelPath:threads:) throws` + C-8/C-9 conformance. If
// the name differs, the fix is ONE LINE in this file (my lane) — the spec
// exists so that does not happen.
//
// The app owns the weights path (J-207's cache, `<name>-<sha256[:16]>`), so
// the engine receives a path and never touches the network (AGENTS §0).

#if canImport(DemucsShim) && SEPARATION_IMPORT_ENGINE

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
            throw ImportError.engineFailure(
                "The separation model (htdemucs, 84 MB) is not on this device yet. Download it in Settings → Models, then import again.")
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw ImportError.engineFailure(
                "The separation model file is missing from the app's cache. Download it again in Settings → Models.")
        }
        do {
            let engine = try SeparationImportEngine(modelPath: modelURL)
            return ImportEngineHandle(
                engine: engine,
                bundleID: { engine.importedBundleID },
                kind: .real)
        } catch {
            throw ImportError.engineFailure("The separation model could not be loaded: \(error)")
        }
    }
}

#endif
