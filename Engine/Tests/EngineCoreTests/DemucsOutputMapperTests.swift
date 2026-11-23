import XCTest
@testable import EngineCore

// P-201 (M2) — portable separation pieces (Linux-tested here; the C++ shim +
// Swift bridge compile Apple-side via project.yml X-task).
final class DemucsOutputMapperTests: XCTestCase {

    /// Synthesizes a deterministic 4-source INTERLEAVED-stereo buffer (the
    /// shim/runner layout): source s, channel c gets a distinct constant
    /// (s+1) * (c == 0 ? 1.0 : -0.5) + tiny per-sample slope so residual-sum
    /// math is verifiable without float-ambiguity.
    private func synth(_ n: Int) -> [Float] {
        var raw = [Float]()
        raw.reserveCapacity(4 * 2 * n)
        for s in 0..<4 {
            let lBase = Float(s + 1) * 1.0
            let rBase = Float(s + 1) * -0.5
            for i in 0..<n {
                let slope = 0.0001 * Float(i % 7)
                raw.append(lBase + slope)
                raw.append(rBase + slope)
            }
        }
        return raw
    }

    func testMapsVocalsFromTargetThree() throws {
        let n = 64
        let raw = synth(n)
        let mapped = try DemucsOutputMapper.map(rawStems: raw, nSamples: n)
        // vocals = target_3 (src index 3): L = 4.0+ε, R = -2.0+ε
        XCTAssertEqual(mapped.vocals.samples[0], raw[3 * 2 * n], accuracy: 1e-6)
        XCTAssertEqual(mapped.vocals.samples[1], raw[3 * 2 * n + 1], accuracy: 1e-6)
        XCTAssertEqual(mapped.vocals.samples.count, 2 * n)
        XCTAssertEqual(mapped.vocals.sampleRate, 44100)
    }

    func testInstrumentalIsResidualSumOfDrumsBassOther() throws {
        let n = 64
        let raw = synth(n)
        let mapped = try DemucsOutputMapper.map(rawStems: raw, nSamples: n)
        // residual L = (1 + 2 + 3) = 6, R = -(0.5 + 1.0 + 1.5) = -3.0;
        // slope ε = 0.0001·(i%7) added positively to BOTH channels per synth —
        // at i=0 it is 0 (exact bases), at i=1 three slopes sum (0.0003).
        XCTAssertEqual(mapped.instrumental.samples[0], 6.0, accuracy: 1e-6)
        XCTAssertEqual(mapped.instrumental.samples[1], -3.0, accuracy: 1e-6)
        let slope3 = 3.0 * 0.0001
        XCTAssertEqual(mapped.instrumental.samples[2], 6.0 + Float(slope3), accuracy: 1e-5)
        XCTAssertEqual(mapped.instrumental.samples[3], -3.0 + Float(slope3), accuracy: 1e-5)
        XCTAssertEqual(mapped.instrumental.samples.count, 2 * n)
    }

    func testMonoDownmixIsChannelMean() throws {
        let n = 4
        let raw = synth(n)
        let mapped = try DemucsOutputMapper.map(rawStems: raw, nSamples: n)
        let mono = mapped.vocals.mono()
        XCTAssertEqual(mono.count, n)
        let want0 = 0.5 * (raw[3 * 2 * n] + raw[3 * 2 * n + 1])
        XCTAssertEqual(mono[0], want0, accuracy: 1e-6)
    }

    func testSizeMismatchThrows() {
        XCTAssertThrowsError(try DemucsOutputMapper.map(rawStems: [Float](repeating: 0, count: 10), nSamples: 8)) { e in
            guard case DemucsOutputMapper.MapperError.sizeMismatch(let expected, let actual) = e else {
                return XCTFail("wrong error \(e)")
            }
            XCTAssertEqual(expected, 64)
            XCTAssertEqual(actual, 10)
        }
    }

    func testNonFiniteThrows() {
        var raw = [Float](repeating: 0.1, count: 4 * 2 * 4)
        raw[2 * 2 * 4 + 3] = Float.nan // first sample of source 1
        XCTAssertThrowsError(try DemucsOutputMapper.map(rawStems: raw, nSamples: 4)) { e in
            guard case DemucsOutputMapper.MapperError.nonFinite(let offset) = e else {
                return XCTFail("wrong error \(e)")
            }
            XCTAssertEqual(offset, 2 * 2 * 4 + 3)
        }
    }
}

final class PCMWavWriterTests: XCTestCase {

    func testRoundTripThroughPCMWaveReader() throws {
        let n = 441
        let samples = (0..<n).map { sinf(Float($0) * 0.1) * 0.5 }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pnmwav-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try PCMWavWriter.write(url: tmp, samples: samples, sampleRate: 44100, channels: 1)
        let read = try PCMWaveReader.read(url: tmp)
        XCTAssertEqual(read.sampleRate, 44100)
        XCTAssertEqual(read.channels, 1)
        XCTAssertEqual(read.samples.count, n)
        // Quantization to int16: worst-case ~1/32768 absolute error.
        for (a, b) in zip(read.samples, samples) {
            XCTAssertEqual(a, b, accuracy: 1.0 / 32768.0)
        }
    }

    func testClampingAndHeaderFields() throws {
        let samples: [Float] = [-2.0, 0.0, 2.0, 0.25]
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pnmwav-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try PCMWavWriter.write(url: tmp, samples: samples, sampleRate: 16000, channels: 1)
        let data = try Data(contentsOf: tmp)
        XCTAssertEqual(data.count, 44 + samples.count * 2)
        XCTAssertEqual(String(data: data.subdata(in: 0..<4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        // sampleRate little-endian at offset 24 (byte assembly — Data slices
        // on Linux Foundation are not alignment-guaranteed for load(as:))
        let srBytes = Array(data.subdata(in: 24..<28))
        let sr = UInt32(srBytes[0]) | UInt32(srBytes[1]) << 8
            | UInt32(srBytes[2]) << 16 | UInt32(srBytes[3]) << 24
        XCTAssertEqual(sr, 16000)
        // PCMWaveReader returns mono-folded samples; quantization to int16
        // via ±32767 scaling: worst case ~1/32768 absolute error.
        let read = try PCMWaveReader.read(url: tmp)
        XCTAssertEqual(read.samples.count, 4)
        XCTAssertEqual(read.samples[0], -1.0, accuracy: 2.0 / 32768.0) // clamped
        XCTAssertEqual(read.samples[3], 0.25, accuracy: 2.0 / 32768.0)
    }

    func testStereoWriteFoldsToMonoOnRead() throws {
        // D-8 instrumental staging is stereo; the reader folds to mono (P-101
        // engine-pitch contract) AFTER the writer's clamp: frame0 (−2→−1, 0)
        // → −0.5, frame1 (1, 0.25) → 0.625.
        let samples: [Float] = [-2.0, 0.0, 2.0, 0.25]
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pnmwav-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try PCMWavWriter.write(url: tmp, samples: samples, sampleRate: 44100, channels: 2)
        let read = try PCMWaveReader.read(url: tmp)
        XCTAssertEqual(read.channels, 2)
        XCTAssertEqual(read.samples.count, 2) // frames, folded
        XCTAssertEqual(read.samples[0], -0.5, accuracy: 2.0 / 32768.0)
        XCTAssertEqual(read.samples[1], 0.625, accuracy: 2.0 / 32768.0)
    }

    func testNonFiniteThrows() {
        XCTAssertThrowsError(try PCMWavWriter.write(
            url: URL(fileURLWithPath: "/tmp/never-written.wav"),
            samples: [0.0, Float.infinity], sampleRate: 44100, channels: 1)) { e in
            guard case PCMWavWriter.WriteError.nonFinite = e else {
                return XCTFail("wrong error \(e)")
            }
        }
    }
}
