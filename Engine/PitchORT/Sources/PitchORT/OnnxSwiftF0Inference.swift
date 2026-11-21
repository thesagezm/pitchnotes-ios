import Foundation
import OnnxRuntimeBindings
import EngineCore

// ONNX Runtime-backed SwiftF0 inference (P-101, PAUL lane).
//
// Implements the portable `SwiftF0Inference` seam (EngineCore) against the
// ORT ObjC wrapper (mirror 1.24.2, D-13; CPU execution provider — CoreML EP
// is an M6 acceleration phase on the SAME model, D-13/PLAN M6).
//
// Model: lars76/swift-f0 `model.onnx` (MIT, D-19-pinned URL + SHA256 in
// Models/manifest.json — weights NEVER in git, AGENTS §4). I/O contract
// (validated by the spike, Tests/Spikes/swiftf0_real.py):
//   in:  "audio" float32 [1, samples] @16 kHz · "fmin"/"fmax" float32 scalars
//   out: "pitch" float64 [1, frames] Hz · "confidence" float32 [1, frames]
// where frames = samples / 256 (model does its own framing).

/// Thread-safe, stateless ONNX forward pass for SwiftF0. Construct once and
/// reuse (session construction allocates the thread pool); `run` may be called
/// from multiple threads (ORT sessions are thread-safe for `run`).
public final class OnnxSwiftF0Inference: SwiftF0Inference, @unchecked Sendable {
    private let session: ORTSession

    /// - Parameters:
    ///   - modelURL: verified SwiftF0 ONNX on disk (downloaded + SHA256-checked
    ///     via `scripts/models/download.py`; see `ModelStore.modelURL(for:)`).
    ///   - intraOpThreads: ORT CPU pool size. §8 budgets say benchmark 2–4 and
    ///     do not oversubscribe the A14's 2P+4E cores (spike measured 1→2→4
    ///     thread scaling: RTF 0.0156 → 0.0098 → 0.0089 on the CI runner).
    public init(modelURL: URL, intraOpThreads: Int = 2) throws {
        let env = try ORTEnv(loggingLevel: .error)
        let options = ORTSessionOptions()
        try options.setIntraOpNumThreads(Int32(intraOpThreads))
        self.session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
    }

    public func run(audio: [Float], fmin: Float, fmax: Float) throws -> (pitch: [Double], confidence: [Float]) {
        let sampleCount = audio.count
        let audioData = audio.withUnsafeBufferPointer { buf -> Data in
            Data(buffer: buf)
        }
        let audioValue = try ORTValue(
            tensorData: NSMutableData(data: audioData),
            elementType: .float,
            shape: [NSNumber(value: 1), NSNumber(value: sampleCount)])
        let fminValue = try ORTValue.makeScalar(Float(fmin))
        let fmaxValue = try ORTValue.makeScalar(Float(fmax))

        let outputs = try session.run(
            withInputs: ["audio": audioValue, "fmin": fminValue, "fmax": fmaxValue],
            outputNames: ["pitch", "confidence"],
            runOptions: nil)

        guard let pitchValue = outputs["pitch"], let confValue = outputs["confidence"] else {
            throw EngineError.modelMissing("SwiftF0 ONNX outputs missing (pitch/confidence)")
        }
        let pitch = try pitchValue.data(as: Double.self, count: frameCount(of: pitchValue))
        let confidence = try confValue.data(as: Float.self, count: frameCount(of: confValue))
        return (pitch, confidence)
    }

    private func frameCount(of value: ORTValue) throws -> Int {
        guard let info = try value.tensorTypeAndShapeInfo() else {
            throw EngineError.contractViolation("SwiftF0 ONNX output has no type/shape info")
        }
        let shape = info.shape
        // [1, frames] → frames = product of trailing dims beyond the batch axis.
        return shape.dropFirst().reduce(1) { $0 * $1.intValue }
    }
}

private extension ORTValue {
    /// Scalar float32 input (fmin/fmax): 0-d tensor over 4 bytes.
    static func makeScalar(_ value: Float) throws -> ORTValue {
        var copy = value
        let data = withUnsafeBytes(of: &copy) { Data($0) }
        return try ORTValue(
            tensorData: NSMutableData(data: data),
            elementType: .float,
            shape: [])
    }

    /// Typed read of this tensor's bytes.
    func data<T: BinaryFloatingPoint>(as: T.Type, count: Int) throws -> [T] {
        let raw = try tensorData()
        let expected = count * MemoryLayout<T>.stride
        guard raw.length == expected else {
            throw EngineError.contractViolation(
                "SwiftF0 ONNX tensor: \(raw.length) bytes, expected \(expected) (\(count) × \(T.self))")
        }
        return raw.withUnsafeBytes { rawBuf in
            Array(rawBuf.bindMemory(to: T.self)).map { T($0) }
        }
    }
}

/// Model file resolution shared by the app + spike flows: the manifest-driven
/// cache (D-2 flow) downloads + SHA256-verifies; this helper only LOCATES the
/// verified file. Verification lives in download.py (single source of truth).
public enum SwiftF0ModelStore {
    /// Cache filename scheme used by `scripts/models/download.py`:
    /// `<name>-<sha256[:16]>`.
    public static func modelURL(for name: String, sha256: String, in cacheDir: URL) -> URL {
        cacheDir.appendingPathComponent("\(name)-\(sha256.prefix(16))")
    }

    /// Look up a named model entry from a manifest JSON and resolve its cached
    /// path under `cacheDir`. Throws `EngineError.modelMissing` when absent —
    /// callers (app first-run flow) then trigger the one-time download.
    public static func locateModel(named name: String, manifestURL: URL, cacheDir: URL) throws -> URL {
        let data = try Data(contentsOf: manifestURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let models = obj?["models"] as? [[String: Any]] else {
            throw EngineError.modelMissing("manifest unreadable: \(manifestURL.path)")
        }
        guard let entry = models.first(where: { ($0["name"] as? String) == name }),
              let sha = entry["sha256"] as? String else {
            throw EngineError.modelMissing("manifest has no '\(name)' entry")
        }
        let url = modelURL(for: name, sha256: sha, in: cacheDir)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EngineError.modelMissing(
                "\(name) not cached at \(url.path) — run scripts/models/download.py --entry \(name)")
        }
        return url
    }

    public static func locateSwiftF0(manifestURL: URL, cacheDir: URL) throws -> URL {
        try locateModel(named: "swiftf0", manifestURL: manifestURL, cacheDir: cacheDir)
    }

    public static func locateSilero(manifestURL: URL, cacheDir: URL) throws -> URL {
        try locateModel(named: "silero-vad", manifestURL: manifestURL, cacheDir: cacheDir)
    }
}
