import XCTest
@testable import PitchORT
import EngineCore

// P-208 (D-24 / CONTRACTS C-7): numerical PARITY of the Swift/ORT SwiftF0
// pipeline against the Python reference tensors captured by
// Tests/Spikes/swiftf0_real.py --export-c7 on the committed fixtures.
//
// End-to-end through the SAME pipeline the device uses:
//   OnnxSwiftF0Inference.run (raw pitch/confidence) →
//   SwiftF0Postprocessor.gateConfidence + .loudness (EngineCore)
// compared tensor-by-tensor within the sidecar's tolerance (abs OR rel).
//
// Skips (loud, with the fix command) only when the model is not cached —
// weights are never in git (AGENTS §4). Missing sidecars are a FAIL (they are
// committed artifacts). macOS-only via the PitchORT package.

final class SwiftF0ParityTests: XCTestCase {

    /// MUST match swiftf0_real.py FMIN/FMAX — the reference was exported with
    /// exactly these model inputs; different bounds change the outputs.
    private static let fmin: Float = 46.875
    private static let fmax: Float = 2093.75

    private static let stems = ["sweep_46_2100Hz_16k", "synthetic_voice_16k", "silence_16k"]

    func testParityOnCommittedFixtures() throws {
        let modelURL = try ParitySupport.locateModel(
            named: "swiftf0",
            entryCommand: "python3 scripts/models/download.py --entry swiftf0")
        let inference = try OnnxSwiftF0Inference(modelURL: modelURL, intraOpThreads: 1)

        for stem in Self.stems {
            let sidecar = try ParitySupport.loadSidecar(slug: "swiftf0", stem: stem)
            try ParitySupport.assertModelBinding(sidecar: sidecar, modelURL: modelURL)
            try ParitySupport.assertFixtureBinding(sidecar: sidecar, fixtureName: sidecar.fixture)

            let wavURL = ParitySupport.repoRoot()
                .appendingPathComponent("Tests/Spikes/Fixtures")
                .appendingPathComponent(sidecar.fixture)
            let pcm = try PCMWaveReader.read(url: wavURL)
            XCTAssertEqual(pcm.sampleRate, 16000, "\(stem): fixture sample-rate contract")
            XCTAssertEqual(pcm.channels, 1, "\(stem): fixture mono contract")

            let audio = pcm.samples
            let raw = try inference.run(audio: audio, fmin: Self.fmin, fmax: Self.fmax)
            let frameCount = raw.confidence.count

            let gated = SwiftF0Postprocessor.gateConfidence(
                audio: audio, frameCount: frameCount, confidence: raw.confidence)
            let loudness = SwiftF0Postprocessor.loudness(audio: audio, frameCount: frameCount)

            for spec in sidecar.tensors {
                let reference = try ParitySupport.loadReferenceDouble(slug: "swiftf0", spec: spec)
                switch spec.name {
                case "pitch_hz":
                    ParitySupport.assertTensorParity(
                        reference: reference, output: raw.pitch,
                        name: spec.name, stem: stem, tolerance: sidecar.tolerance)
                case "confidence_raw":
                    ParitySupport.assertTensorParity(
                        reference: reference, output: raw.confidence.map(Double.init),
                        name: spec.name, stem: stem, tolerance: sidecar.tolerance)
                case "confidence_gated":
                    ParitySupport.assertTensorParity(
                        reference: reference, output: gated.map(Double.init),
                        name: spec.name, stem: stem, tolerance: sidecar.tolerance)
                case "loudness_db":
                    ParitySupport.assertTensorParity(
                        reference: reference, output: loudness,
                        name: spec.name, stem: stem, tolerance: sidecar.tolerance)
                default:
                    XCTFail("\(stem): unknown tensor \(spec.name) in sidecar — update the parity test")
                }
            }
        }
    }
}
