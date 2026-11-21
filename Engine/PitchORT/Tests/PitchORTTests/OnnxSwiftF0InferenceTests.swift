import XCTest
@testable import PitchORT
import EngineCore

// Real-model Swift end-to-end (P-101, macOS only — the Python spike covers the
// model contract; these tests cover the SWIFT ORT session + portable pipeline
// glue with the actual pinned ONNX).
//
// Model resolution: $HOME/pitchnotes-model-cache (filled by the logic-tests
// download step on CI) → $HOME/.cache/pitchnotes-models (local Linux/manual)
// → Models/downloads. Skips when the model is not cached (run
// `python3 scripts/models/download.py --entry swiftf0 --cache-dir <dir>`).

final class OnnxSwiftF0InferenceTests: XCTestCase {

    private func locateModel() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("pitchnotes-model-cache"),
            home.appendingPathComponent(".cache/pitchnotes-models"),
            URL(fileURLWithPath: #filePath) // repo-root fallback below
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Models/downloads"),
        ]
        let manifest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Models/manifest.json")
        for cache in candidates {
            if let url = try? SwiftF0ModelStore.locateSwiftF0(manifestURL: manifest, cacheDir: cache) {
                return url
            }
        }
        throw XCTSkip("SwiftF0 ONNX not cached (run scripts/models/download.py) — real-model test skipped")
    }

    private func sine(_ hz: Double, seconds: Double, amplitude: Float = 0.5) -> [Float] {
        let n = Int(seconds * Double(SwiftF0Spec.sampleRate))
        return (0..<n).map { Float(amplitude * sin(2.0 * .pi * hz * Double($0) / Double(SwiftF0Spec.sampleRate))) }
    }

    func testOnnxSessionDetectsSteadyToneWithin20Cents() throws {
        let engine = SwiftF0PitchEngine(inference: try OnnxSwiftF0Inference(modelURL: try locateModel()))
        let frames = try engine.detect(samples: sine(220.0, seconds: 2.0), sampleRate: 16_000)
        let voiced = frames.filter { $0.contractPitchFrame.hz > 0 }
        XCTAssertGreaterThan(voiced.count, 100, "steady tone must be voiced most frames (\(voiced.count)/\(frames.count))")
        let cents = voiced.map { abs(1200.0 * log2($0.hz / 220.0)) }
        let median = cents.sorted()[cents.count / 2]
        XCTAssertLessThan(median, 20.0, "median |cents| \(median)")
    }

    func testOnnxSilenceFullyGated() throws {
        let engine = SwiftF0PitchEngine(inference: try OnnxSwiftF0Inference(modelURL: try locateModel()))
        let frames = try engine.detect(samples: [Float](repeating: 0, count: 2 * SwiftF0Spec.sampleRate), sampleRate: 16_000)
        XCTAssertTrue(frames.allSatisfy { $0.contractPitchFrame.hz == 0.0 },
                      "digital silence must map to unvoiced via the gate")
    }

    func testOnnxStreamingMatchesBatch() throws {
        let modelURL = try locateModel()
        let batch = try SwiftF0PitchEngine(inference: OnnxSwiftF0Inference(modelURL: modelURL))
            .detect(samples: sine(146.83, seconds: 2.0), sampleRate: 16_000)
        let stream = try SwiftF0PitchEngine(inference: OnnxSwiftF0Inference(modelURL: modelURL))
            .stream()
        let audio = sine(146.83, seconds: 2.0)
        var streamed: [SwiftF0Frame] = []
        var i = 0
        while i < audio.count {
            let n = min(640, audio.count - i) // 40 ms mic-style chunks
            streamed += try stream.push(Array(audio[i..<i + n]))
            i += n
        }
        streamed += try stream.flush()
        XCTAssertEqual(streamed.count, batch.count)
        for (a, b) in zip(streamed, batch) {
            XCTAssertEqual(a.hz, b.hz, accuracy: 1e-6, "stream must reproduce batch (lookahead satisfied)")
            XCTAssertEqual(a.confidence, b.confidence, accuracy: 1e-6)
        }
    }

    func testOnnxResampled441kPath() throws {
        let engine = SwiftF0PitchEngine(inference: try OnnxSwiftF0Inference(modelURL: try locateModel()))
        let sr = 44_100
        let n = Int(1.5 * Double(sr))
        let audio = (0..<n).map { Float(0.5 * sin(2.0 * .pi * 110.0 * Double($0) / Double(sr))) }
        let frames = try engine.detect(samples: audio, sampleRate: sr)
        let voiced = frames.filter { $0.contractPitchFrame.hz > 0 }
        XCTAssertGreaterThan(voiced.count, 60, "44.1k→16k path must stay voiced")
        let cents = voiced.map { abs(1200.0 * log2($0.hz / 110.0)) }
        let median = cents.sorted()[cents.count / 2]
        XCTAssertLessThan(median, 20.0, "median |cents| after resampling \(median)")
    }
}
