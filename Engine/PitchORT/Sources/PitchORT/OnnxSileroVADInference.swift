import Foundation
import OnnxRuntimeBindings
import EngineCore

// ONNX Runtime-backed silero-vad inference (P-103, PAUL lane).
//
// Implements the portable `SileroVADInference` seam (EngineCore) against the
// ORT ObjC wrapper (mirror 1.24.2, D-13), CPU execution provider.
//
// Model: snakers4/silero-vad `silero_vad.onnx` (MIT, D-19-pinned commit
// bfdc019 + SHA256 in Models/manifest.json). I/O (validated by the spike):
//   in:  "input" f32 [1, 576] (64 context + 512 chunk) · "state" f32 [2,1,128]
//        · "sr" int64 scalar (16000)
//   out: "output" f32 [1, 1] (speech prob) · "stateN" f32 [2, 1, 128]

/// Thread-safe per-call ONNX forward for silero-vad. The RECURRENT state is
/// owned by `SileroVADStream` (portable) and passed through every call — this
/// class stays stateless.
public final class OnnxSileroVADInference: SileroVADInference, @unchecked Sendable {
    private let session: ORTSession

    public init(modelURL: URL, intraOpThreads: Int = 1) throws {
        let env = try ORTEnv(loggingLevel: .error)
        let options = ORTSessionOptions()
        try options.setIntraOpNumThreads(Int32(intraOpThreads))
        self.session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
    }

    public func run(input: [Float], state: [Float], sampleRate: Int) throws -> (prob: Float, newState: [Float]) {
        let inputValue = try ORTValue(
            tensorData: NSMutableData(data: input.withUnsafeBufferPointer { Data(buffer: $0) }),
            elementType: .float,
            shape: [NSNumber(value: 1), NSNumber(value: input.count)])
        let stateValue = try ORTValue(
            tensorData: NSMutableData(data: state.withUnsafeBufferPointer { Data(buffer: $0) }),
            elementType: .float,
            shape: [NSNumber(value: 2), NSNumber(value: 1), NSNumber(value: 128)])
        let srValue = try scalarInt64(Int64(sampleRate))

        let outputs = try session.run(
            withInputs: ["input": inputValue, "state": stateValue, "sr": srValue],
            outputNames: ["output", "stateN"],
            runOptions: nil)
        guard let outValue = outputs["output"], let stateValueN = outputs["stateN"] else {
            throw EngineError.modelMissing("silero-vad ONNX outputs missing (output/stateN)")
        }
        let outData = try outValue.tensorData()
        guard outData.length >= MemoryLayout<Float>.stride else {
            throw EngineError.contractViolation("silero-vad output tensor too small")
        }
        let prob = outData.withUnsafeBytes { $0.load(as: Float.self) }
        let newState = try stateValueN.data(as: Float.self, count: SileroVADSpec.stateSize)
        return (prob, newState)
    }

    private func scalarInt64(_ value: Int64) throws -> ORTValue {
        var copy = value
        let data = withUnsafeBytes(of: &copy) { Data($0) }
        return try ORTValue(
            tensorData: NSMutableData(data: data),
            elementType: .int64,
            shape: [])
    }
}
