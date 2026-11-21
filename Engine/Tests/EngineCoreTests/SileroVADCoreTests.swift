import XCTest
@testable import EngineCore

// SileroVAD portable-core tests (P-103): chunking, context/state recurrence,
// reset, gate hysteresis — scripted mock inference (real model covered by the
// Python spike + PitchORT macOS tests).

final class SileroVADCoreTests: XCTestCase {

    /// Scripted mock: verifies upstream streaming contract on EVERY call and
    /// returns the probability for the chunk from a fixed script.
    private final class ScriptedInference: SileroVADInference, @unchecked Sendable {
        private(set) var inputs: [[Float]] = []
        private(set) var returnedStates: [[Float]] = []
        private let probs: [Float]
        private var call = 0
        /// Test hook after `SileroVADStream.reset()`: the next call is treated
        /// as a fresh first call (zeros context/state are EXPECTED again).
        func markReset() {
            inputs.removeAll()
            returnedStates.removeAll()
        }
        init(probs: [Float]) { self.probs = probs }
        func run(input: [Float], state: [Float], sampleRate: Int) throws -> (prob: Float, newState: [Float]) {
            XCTAssertEqual(input.count, SileroVADSpec.contextSamples + SileroVADSpec.chunkSamples)
            XCTAssertEqual(state.count, SileroVADSpec.stateSize)
            XCTAssertEqual(sampleRate, 16000)
            // Upstream context semantics: input[0..<64] == last 64 samples of
            // the PREVIOUS input (zeros on the first call).
            if let prev = inputs.last {
                XCTAssertEqual(Array(input[0..<SileroVADSpec.contextSamples]),
                               Array(prev[(prev.count - SileroVADSpec.contextSamples)...]),
                               "context must carry over from the previous chunk")
            } else {
                XCTAssertTrue(input[0..<SileroVADSpec.contextSamples].allSatisfy { $0 == 0 },
                              "first call context must be zeros")
            }
            // Upstream state semantics: first call zeros; then the PREVIOUS
            // call's RETURNED newState must come back in.
            if let lastReturned = returnedStates.last {
                XCTAssertEqual(state, lastReturned, "state must be the previous call's returned newState")
            } else {
                XCTAssertTrue(state.allSatisfy { $0 == 0 }, "initial state must be zeros")
            }
            inputs.append(input)
            defer { call += 1 }
            let newState = (0..<SileroVADSpec.stateSize).map { Float(call + 1) + Float($0) * 0.001 }
            returnedStates.append(newState)
            return (probs[min(call, probs.count - 1)], newState)
        }
    }

    func testChunkAccumulationEmitsPer512Samples() throws {
        let inf = ScriptedInference(probs: [0.9, 0.8, 0.7, 0.6, 0.6])
        let stream = SileroVADStream(inference: inf)
        // 32 ms pushes (exactly 512): one chunk per push.
        var emitted: [Float] = []
        for _ in 0..<4 {
            emitted += try stream.push([Float](repeating: 0.5, count: 512))
        }
        XCTAssertEqual(emitted, [0.9, 0.8, 0.7, 0.6])
        XCTAssertEqual(inf.inputs.count, 4)
        // Mic-style 40 ms pushes (640 samples): leftover 128 samples accumulate
        // across pushes — emission count follows 512-sample boundaries, not pushes.
        emitted += try stream.push([Float](repeating: 0.5, count: 640))
        XCTAssertEqual(emitted.count, 5, "640 = 1 chunk + 128 pending")
        XCTAssertTrue(try stream.push([Float](repeating: 0.5, count: 256)).isEmpty,
                      "128 + 256 = 384 < 512 → still pending")
        XCTAssertEqual(try stream.push([Float](repeating: 0.5, count: 128)),
                       [probs_get(inf, 6)], "384 + 128 completes the 6th chunk")
    }

    private func probs_get(_ inf: ScriptedInference, _ i: Int) -> Float { 0.6 }

    func testContextAndStateRecur() throws {
        let inf = ScriptedInference(probs: [Float](repeating: 0.5, count: 8))
        let stream = SileroVADStream(inference: inf)
        for _ in 0..<8 { _ = try stream.push([Float](repeating: 0.25, count: 512)) }
        // First input: 64 zeros context + chunk. Second onward: previous tail.
        let first = inf.inputs[0]
        XCTAssertTrue(first[0..<64].allSatisfy { $0 == 0 })
        XCTAssertTrue(first[64...].allSatisfy { $0 == 0.25 })
        let second = inf.inputs[1]
        XCTAssertEqual(Array(second[0..<64]), Array(first[(first.count - 64)...]),
                       "context = last 64 samples of previous (context+chunk) input")
        // Mock returns a call-dependent newState — verify the fed-back state
        // advanced each call (state[1] is call-1's echo fed into call 2, etc.).
        XCTAssertNotEqual(inf.returnedStates[0], inf.returnedStates[7])
        for (a, b) in zip(inf.returnedStates, inf.returnedStates.dropFirst()) {
            XCTAssertNotEqual(a, b, "state must advance every call")
        }
    }

    func testResetRestoresZeros() throws {
        let inf = ScriptedInference(probs: [Float](repeating: 0.9, count: 4))
        let stream = SileroVADStream(inference: inf)
        for _ in 0..<2 { _ = try stream.push([Float](repeating: 0.5, count: 512)) }
        stream.reset()
        inf.markReset()
        _ = try stream.push([Float](repeating: 0.5, count: 512))
        XCTAssertEqual(inf.inputs.count, 1)
        XCTAssertTrue(inf.inputs.last![0..<64].allSatisfy { $0 == 0 }, "context reset to zeros")
        // Incoming state was zeros: the mock's first-call branch asserted it (no failure).
    }

    func testVADGateHysteresisAndHang() {
        // Open at ≥0.5, close below 0.35, 5-chunk hang.
        var gate = VADGate()
        // Rising but below on-threshold → closed.
        XCTAssertFalse(gate.observe(prob: 0.45))
        // Open.
        XCTAssertTrue(gate.observe(prob: 0.6))
        // Low but within hang → stays open.
        XCTAssertTrue(gate.observe(prob: 0.30))
        XCTAssertTrue(gate.observe(prob: 0.20))
        // 5-chunk hang: chunks 2..6 after last open stay open, then closes.
        for _ in 0..<3 { XCTAssertTrue(gate.observe(prob: 0.30), "hang window") }
        XCTAssertFalse(gate.observe(prob: 0.30), "closes after hang expires")
        // Immediate reopen.
        XCTAssertTrue(gate.observe(prob: 0.5))
    }
}
