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

    /// Speech-LIKE fixture (mirrors scripts/fixtures/gen.py synthetic_voice):
    /// silero is a SPEECH VAD — a pure sine scores ~0.08 (Python-verified:
    /// pure tone 0.0835, this fixture 0.8647), so the voice-detection test
    /// feeds a harmonic-rich signal, not a tone. Deterministic LCG noise
    /// floor instead of SeededGeneratorType (stable across platforms).
    private func voiceLike(seconds: Double, f0: Double = 130.81, amplitude: Double = 0.4) -> [Float] {
        let n = Int(seconds * Double(SileroVADSpec.sampleRate))
        let w = 2.0 * Double.pi * f0 / Double(SileroVADSpec.sampleRate)
        let harmonics: [(Double, Double)] = [(1, 1.0), (2, 0.60), (3, 0.45), (4, 0.28), (5, 0.18)]
        var state: UInt64 = 0x5EED
        return (0..<n).map { i -> Float in
            var s = 0.0
            let phase = w * Double(i)
            for (mult, a) in harmonics { s += a * sin(Double(mult) * phase) }
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let noise = Double(Int64(bitPattern: state >> 11)) / Double(Int64.max) * 0.003
            return Float(amplitude * (s + noise))
        }
    }

    func testSilenceGatedAndVoiceDetected() throws {
        let stream = SileroVADStream(inference: try OnnxSileroVADInference(modelURL: try locateModel()))
        let silence = try stream.push([Float](repeating: 0, count: 2 * SileroVADSpec.sampleRate))
        XCTAssertLessThan(silence.max() ?? 1.0, 0.05, "digital silence must gate (Swift seam)")

        stream.reset()
        let voice = try stream.push(voiceLike(seconds: 5.0))
        XCTAssertGreaterThanOrEqual(voice.max() ?? 0.0, 0.5,
                                    "speech-like fixture detected (Python ground truth 0.8647; pure sine is NOT speech for this model)")
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
