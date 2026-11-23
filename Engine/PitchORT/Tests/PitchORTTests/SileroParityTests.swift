import XCTest
@testable import PitchORT
import EngineCore

// P-208 (D-24 / CONTRACTS C-7): numerical PARITY of the Swift/ORT silero-vad
// pipeline against the Python reference (Tests/Spikes/silero_real.py
// --export-c7): per-512-sample-chunk speech probabilities on 4 committed
// fixtures, SileroStream streaming semantics (context 64 + recurrent state,
// both carried inside SileroVADStream).
//
// Skips only when the model is not cached (weights never in git); missing
// sidecars are a FAIL (committed artifacts). macOS-only via PitchORT.

final class SileroParityTests: XCTestCase {

    private static let stems = [
        "silence_16k", "noise_burst_16k", "click_track_16k", "synthetic_voice_16k",
    ]

    func testParityOnCommittedFixtures() throws {
        let modelURL = try ParitySupport.locateModel(
            named: "silero-vad",
            entryCommand: "python3 scripts/models/download.py --entry silero-vad")
        let inference = try OnnxSileroVADInference(modelURL: modelURL, intraOpThreads: 1)

        for stem in Self.stems {
            let sidecar = try ParitySupport.loadSidecar(slug: "silero-vad", stem: stem)
            try ParitySupport.assertModelBinding(sidecar: sidecar, modelURL: modelURL)
            try ParitySupport.assertFixtureBinding(sidecar: sidecar, fixtureName: sidecar.fixture)

            let wavURL = ParitySupport.repoRoot()
                .appendingPathComponent("Tests/Spikes/Fixtures")
                .appendingPathComponent(sidecar.fixture)
            let pcm = try PCMWaveReader.read(url: wavURL)
            XCTAssertEqual(pcm.sampleRate, 16000, "\(stem): fixture sample-rate contract")
            XCTAssertEqual(pcm.channels, 1, "\(stem): fixture mono contract")

            // Fresh stream per fixture — mirrors probs_for/SileroStream (Python
            // resets state + context per fixture).
            let stream = SileroVADStream(inference: inference)
            let probs = try stream.push(pcm.samples)

            let spec = try XCTUnwrap(sidecar.tensors.first { $0.name == "speech_prob" },
                                     "\(stem): sidecar has no speech_prob tensor")
            let reference = try ParitySupport.loadReferenceDouble(slug: "silero-vad", spec: spec)
            ParitySupport.assertTensorParity(
                reference: reference, output: probs.map(Double.init),
                name: spec.name, stem: stem, tolerance: sidecar.tolerance)
        }
    }
}
