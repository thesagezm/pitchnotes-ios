import Foundation

// P-201 (M2): portable PCM16 WAV writer — the write-side twin of
// PCMWaveReader (P-101). Used by DemucsEngine to stage separation stems on
// disk; P-204 (ALAC) replaces the SHIPPED stem encoding via AVFoundation and
// keeps this writer for staging/debug paths. Foundation-only (Linux-tested).
public enum PCMWavWriter {

    public enum WriteError: Error, Sendable {
        case emptySamples
        case nonFinite(offset: Int)
        case ioFailure(String)
    }

    /// Writes a 16-bit PCM WAV file. `samples` interleaved per `channels`.
    /// Values are clamped to [-1, 1] before quantization.
    public static func write(url: URL, samples: [Float], sampleRate: Int,
                             channels: Int) throws {
        guard !samples.isEmpty else { throw WriteError.emptySamples }
        for (i, v) in samples.enumerated() where !v.isFinite {
            throw WriteError.nonFinite(offset: i)
        }

        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let dataBytes = samples.count * bytesPerSample
        let byteRate = sampleRate * channels * bytesPerSample

        var pcm = Data()
        pcm.reserveCapacity(44 + dataBytes)
        func ascii(_ s: String) { pcm.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) } }

        ascii("RIFF")
        u32(UInt32(36 + dataBytes))
        ascii("WAVE")
        ascii("fmt ")
        u32(16)                    // fmt chunk size
        u16(1)                     // PCM
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(byteRate))
        u16(UInt16(channels * bytesPerSample)) // block align
        u16(UInt16(bitsPerSample))
        ascii("data")
        u32(UInt32(dataBytes))

        // Quantize: clamp then scale to int16 (symmetric full scale 32767,
        // round-to-nearest — truncation doubles the worst-case error).
        for v in samples {
            let clamped = max(-1.0, min(1.0, Double(v)))
            let s = Int16((clamped * 32767.0).rounded()).littleEndian
            withUnsafeBytes(of: s) { pcm.append(contentsOf: $0) }
        }

        do {
            try pcm.write(to: url)
        } catch {
            throw WriteError.ioFailure(url.path)
        }
    }
}
