import Foundation

/// Minimal portable RIFF/WAVE reader (P-101). Supports the formats this
/// project produces and consumes offline: PCM16 and IEEE-float32, mono or
/// stereo (stereo is averaged to mono — engine pitch paths are mono).
/// Compressed formats (MP3/FLAC) decode via AVAudioFile in the Apple layer
/// (P-203) and never reach this reader.
public enum PCMWaveReader {
    public struct Content: Sendable {
        /// Mono samples in [-1, 1].
        public let samples: [Float]
        public let sampleRate: Int
        /// Source channel count (samples are already mono-folded).
        public let channels: Int

        public init(samples: [Float], sampleRate: Int, channels: Int) {
            self.samples = samples
            self.sampleRate = sampleRate
            self.channels = channels
        }
    }

    public enum WaveError: Error, Sendable {
        case notRIFF(String)
        case unsupportedFormat(String)
        case truncated(String)
    }

    public static func read(url: URL) throws -> Content {
        let data = try Data(contentsOf: url)
        return try read(data: data)
    }

    public static func read(data: Data) throws -> Content {
        let bytes = [UInt8](data)
        guard bytes.count >= 12,
              String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE" else {
            throw WaveError.notRIFF("missing RIFF/WAVE header")
        }

        var sampleRate = 0
        var channels = 0
        var bitsPerSample = 0
        var audioFormat: UInt16 = 0
        var payload: ArraySlice<UInt8>?

        var offset = 12
        while offset + 8 <= bytes.count {
            let chunkID = String(bytes: bytes[offset..<offset + 4], encoding: .ascii) ?? ""
            let size = Int(readU32(bytes, offset + 4))
            let body = offset + 8
            guard body + size <= bytes.count else {
                throw WaveError.truncated("chunk '\(chunkID)' claims \(size) bytes past EOF")
            }
            switch chunkID {
            case "fmt ":
                audioFormat = readU16(bytes, body)
                channels = Int(readU16(bytes, body + 2))
                sampleRate = Int(readU32(bytes, body + 4))
                bitsPerSample = Int(readU16(bytes, body + 14))
            case "data":
                payload = bytes[body..<body + size]
            default:
                break // skip (LIST, bext, …)
            }
            offset = body + size + (size & 1) // chunks are word-aligned
        }

        guard let data0 = payload, sampleRate > 0, channels > 0 else {
            throw WaveError.truncated("missing fmt/data chunks")
        }
        // WAVE_FORMAT_EXTENSIBLE (0xFFFE) with PCM/float sub-format passes when
        // bits/sample identifies it; we do not chase the GUID.
        guard audioFormat == 1 || audioFormat == 3 || audioFormat == 0xFFFE else {
            throw WaveError.unsupportedFormat("audio format \(audioFormat) (need PCM=1 or float=3)")
        }
        guard bitsPerSample == 16 || bitsPerSample == 32 else {
            throw WaveError.unsupportedFormat("bits/sample \(bitsPerSample) (need 16 or 32)")
        }
        let isFloat = audioFormat == 3 || (audioFormat == 0xFFFE && bitsPerSample == 32)
        let bytesPerSample = bitsPerSample / 8
        let frames = data0.count / (bytesPerSample * channels)

        var samples = [Float](repeating: 0, count: frames)
        let base = data0.startIndex
        for f in 0..<frames {
            var mono: Float = 0
            for c in 0..<channels {
                let p = base + (f * channels + c) * bytesPerSample
                let v: Float
                if isFloat {
                    v = readF32(bytes, p)
                } else {
                    v = Float(Int16(bitPattern: readU16(bytes, p))) / 32768.0
                }
                mono += v
            }
            samples[f] = mono / Float(channels)
        }
        return Content(samples: samples, sampleRate: sampleRate, channels: channels)
    }

    private static func readU16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    private static func readU32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }

    private static func readF32(_ b: [UInt8], _ i: Int) -> Float {
        let bits = readU32(b, i)
        return Float(bitPattern: bits)
    }
}
