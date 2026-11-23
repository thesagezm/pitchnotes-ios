import XCTest
import CryptoKit
import EngineCore
import PitchORT

// P-208 (D-24 / CONTRACTS C-7) parity support: C-7 sidecar decoding, raw-bin
// tensor loading, and the tolerance criterion. macOS-only (PitchORT is the
// Apple-only ORT seam); the sidecars/bins are COMMITTED under
// Tests/Spikes/ReferenceTensors/<slug>/ (regenerable via *_real.py --export-c7).

struct C7Sidecar: Decodable {
    struct TensorSpec: Decodable {
        let name: String
        let file: String
        let shape: [Int]
        let dtype: String
    }

    struct ExportInfo: Decodable {
        let source: String
        let script: String
        let date: String
    }

    struct Tolerance: Decodable {
        let abs: Double
        let rel: Double
    }

    let referenceVersion: Int
    let engine: String
    let fixture: String
    let fixtureSHA256: String
    let modelSHA256: String
    let export: ExportInfo
    let tensors: [TensorSpec]
    let tolerance: Tolerance

    enum CodingKeys: String, CodingKey {
        case referenceVersion, engine, fixture, export, tensors, tolerance
        case fixtureSHA256 = "fixture_sha256"
        case modelSHA256 = "model_sha256"
    }
}

enum ParitySupport {
    /// Repo root from the test file location:
    /// <root>/Engine/PitchORT/Tests/PitchORTTests/<file> → 5 deletes.
    static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PitchORTTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // PitchORT
            .deletingLastPathComponent() // Engine
            .deletingLastPathComponent() // repo root
    }

    /// Model cache candidates (mirrors the existing PitchORT tests): the two
    /// home caches + the download.py default (repo-relative Models/downloads).
    static func modelCacheCandidates() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("pitchnotes-model-cache"),
            home.appendingPathComponent(".cache/pitchnotes-models"),
            repoRoot().appendingPathComponent("Models/downloads"),
        ]
    }

    /// Loud skip when the model is not cached (weights NEVER in git, AGENTS §4):
    /// the skip message carries the exact fix so CI/local failures are actionable.
    static func locateModel(named name: String, entryCommand: String) throws -> URL {
        let manifestURL = repoRoot().appendingPathComponent("Models/manifest.json")
        var lastError: Error?
        for cache in modelCacheCandidates() {
            do {
                return try SwiftF0ModelStore.locateModel(named: name, manifestURL: manifestURL, cacheDir: cache)
            } catch {
                lastError = error
            }
        }
        throw XCTSkip("\(name) ONNX not cached in any known location (\(lastError?.localizedDescription ?? "?")) — fix: \(entryCommand)")
    }

    /// Load a committed C-7 sidecar. Missing sidecar = FAIL (repo error), not
    /// a skip — the sidecars are committed artifacts of P-208.
    static func loadSidecar(slug: String, stem: String) throws -> C7Sidecar {
        let url = repoRoot()
            .appendingPathComponent("Tests/Spikes/ReferenceTensors")
            .appendingPathComponent(slug)
            .appendingPathComponent("\(stem).json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("C-7 sidecar missing: \(url.path) — regenerate via the *_real.py --export-c7 exporter")
            throw EngineError.modelMissing("sidecar missing: \(url.path)")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(C7Sidecar.self, from: data)
    }

    /// D-24 binding invariant (ReferenceTensors/README.md): the reference was
    /// captured from a specific pinned model — a model bump without
    /// regeneration must fail loudly BEFORE any tensor comparison.
    static func assertModelBinding(sidecar: C7Sidecar, modelURL: URL) throws {
        let data = try Data(contentsOf: modelURL)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, sidecar.modelSHA256,
                       "\(modelURL.lastPathComponent) sha256 does not match the sidecar's model_sha256 — the pinned model changed; regenerate the C-7 sidecars (--export-c7) before parity.")
    }

    static func assertFixtureBinding(sidecar: C7Sidecar, fixtureName: String) throws {
        let url = repoRoot().appendingPathComponent("Tests/Spikes/Fixtures").appendingPathComponent(fixtureName)
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, sidecar.fixtureSHA256,
                       "fixture \(fixtureName) bytes changed since the reference was captured — regenerate the C-7 sidecars.")
    }

    /// Reference tensor → [Double] (f32 bins widen losslessly).
    static func loadReferenceDouble(slug: String, spec: C7Sidecar.TensorSpec) throws -> [Double] {
        let url = repoRoot()
            .appendingPathComponent("Tests/Spikes/ReferenceTensors")
            .appendingPathComponent(slug)
            .appendingPathComponent(spec.file)
        let data = try Data(contentsOf: url)
        switch spec.dtype {
        case "float32":
            let n = data.count / MemoryLayout<Float>.stride
            var buf = [Float](repeating: 0, count: n)
            _ = buf.withUnsafeMutableBytes { data.copyBytes(to: $0) }
            return buf.map(Double.init)
        case "float64":
            let n = data.count / MemoryLayout<Double>.stride
            var buf = [Double](repeating: 0, count: n)
            _ = buf.withUnsafeMutableBytes { data.copyBytes(to: $0) }
            return buf
        default:
            XCTFail("unsupported C-7 dtype \(spec.dtype) in \(spec.file)")
            throw EngineError.contractViolation("unsupported C-7 dtype \(spec.dtype)")
        }
    }

    /// C-7 pass criterion: EVERY element within tolerance (abs OR rel of the
    /// reference). Reports the worst deviation on failure for the CI log.
    static func assertTensorParity(reference: [Double], output: [Double],
                                   name: String, stem: String,
                                   tolerance: C7Sidecar.Tolerance) {
        XCTAssertEqual(reference.count, output.count,
                       "\(stem).\(name): frame count \(output.count) != reference \(reference.count)")
        guard reference.count == output.count else { return }
        var worstAbs = 0.0
        var worstIndex = 0
        var violations = 0
        for (i, ref) in reference.enumerated() {
            let d = abs(output[i] - ref)
            if d <= tolerance.abs { continue }                        // abs branch
            if ref != 0 && d <= tolerance.rel * abs(ref) { continue } // rel branch
            violations += 1
            if d > worstAbs { worstAbs = d; worstIndex = i }
        }
        let detail = "\(stem).\(name): parity violations \(violations)/\(reference.count) frames; " +
            "worst at frame \(worstIndex), |Δ|=\(worstAbs) exceeds tolerance " +
            "(abs \(tolerance.abs) OR rel \(tolerance.rel))"
        XCTAssertEqual(violations, 0, detail)
    }
}
