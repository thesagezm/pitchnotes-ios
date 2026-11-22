import XCTest
@testable import PitchORT
import EngineCore

// Real-model silero-vad end-to-end through the SWIFT seam (P-103, macOS only;
// the Python spike covers the model contract, these cover the Swift ORT glue).
// Skips when the model is not in a known cache location.

final class OnnxSileroVADInferenceTests: XCTestCase {

    private func locateModel() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("pitchnotes-model-cache"),
            home.appendingPathComponent(".cache/pitchnotes-models"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Models/downloads"),
        ]
        let manifest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Models/manifest.json")
        for cache in candidates {
            if let url = try? SwiftF0ModelStore.locateSilero(manifestURL: manifest, cacheDir: cache) {
                return url
            }
        }
        throw XCTSkip("silero-vad ONNX not cached (run scripts/models/download.py) — real-model test skipped")
    }

    private func sine(_ hz: Double, seconds: Double, amplitude: Float = 0.5) -> [Float] {
        let n = Int(seconds * Double(SileroVADSpec.sampleRate))
        // Precompute the radian step: the one-liner type-check-timeout-crashes
        // the compiler (X-013, run 44981256783).
        let w = 2.0 * Double.pi * hz / Double(SileroVADSpec.sampleRate)
        return (0..<n).map { i in Float(amplitude) * Float(sin(w * Double(i))) }
    }

    func testSilenceGatedAndVoiceDetected() throws {
        let stream = SileroVADStream(inference: try OnnxSileroVADInference(modelURL: try locateModel()))
        let silence = try stream.push([Float](repeating: 0, count: 2 * SileroVADSpec.sampleRate))
        XCTAssertLessThan(silence.max() ?? 1.0, 0.05, "digital silence must gate (Swift seam)")

        stream.reset()
        let voice = try stream.push(sine(146.83, seconds: 5.0))
        XCTAssertGreaterThanOrEqual(voice.max() ?? 0.0, 0.5, "voice-like harmonic fixture detected (Swift seam)")
        for p in voice {
            XCTAssertTrue(p >= 0 && p <= 1, "prob bounds")
        }
    }

    func testArbitraryChunkSizesMatchPythonProbe() throws {
        // The portable stream must be invariant to push granularity: two runs
        // over the same audio with different chunk splits produce identical probs.
        let model = try locateModel()
        let audio = sine(146.83, seconds: 3.0)
        let s1 = SileroVADStream(inference: try OnnxSileroVADInference(modelURL: model))
        var byMic: [Float] = []
        var i = 0
        while i < audio.count {
            byMic += try s1.push(Array(audio[i..<min(i + 640, audio.count)])) // 40 ms mic chunks
            i += 640
        }
        let s2 = SileroVADStream(inference: try OnnxSileroVADInference(modelURL: model))
        var by32ms: [Float] = []
        i = 0
        while i < audio.count {
            by32ms += try s2.push(Array(audio[i..<min(i + 512, audio.count)]))
            i += 512
        }
        XCTAssertEqual(byMic, by32ms, "probs invariant to push granularity (576-sample effective chunk)")
    }
}
