import Foundation

// P-203 · Import/decode core (C-8 `decoding` stage): container decode →
// normalized 44.1 kHz mix on disk. The seam (`AudioDecoding`) is portable
// (no AVFoundation types — C-3 rule); the Apple-only conformer is
// AVAudioFileDecoder in Engine/ImportKit (X-204 wiring). EngineCore ships a
// channel-preserving WAV conformer so the whole pipeline is Linux-testable.
//
// Policies (D-8): decoded mix = 44.1 kHz; mix channels = source channels
// clamped to {1, 2} (> 2 ch sources mean-downmix to stereo — pairs of
// channels, left = even indices, right = odd). Per-stem channel policy
// (voice MONO / INSTRUMENTAL STEREO) is the separation/mapper's concern
// (DemucsOutputMapper, P-204), not the mix decode's.

public enum DecodePolicy {
    /// D-8: everything downstream of import is 44.1 kHz.
    public static let targetSampleRate = 44100

    /// Channel count of the DECODED MIX (C-2.1 `channels`, V14: 1 or 2).
    public static func mixChannels(sourceChannels: Int) throws -> Int {
        guard sourceChannels >= 1 else {
            throw EngineError.importFailed("invalid source channel count \(sourceChannels)")
        }
        return sourceChannels == 1 ? 1 : 2
    }

    /// Applies the mix policy to channel-interleaved frames: 1 ch passthrough,
    /// 2 ch passthrough, > 2 ch mean-downmix (channel pairs → L/R means).
    public static func applyMixChannelPolicy(interleaved: [Float], sourceChannels: Int) throws
        -> (samples: [Float], channels: Int) {
        switch try mixChannels(sourceChannels: sourceChannels) {
        case 1:
            guard sourceChannels == 1 else {
                throw EngineError.importFailed("mono policy with \(sourceChannels) source channels")
            }
            return (interleaved, 1)
        case 2:
            guard sourceChannels == 2 else {
                // > 2 ch: downmix pairs to L/R means.
                let frames = interleaved.count / sourceChannels
                var out = [Float](repeating: 0, count: frames * 2)
                for f in 0..<frames {
                    var l: Float = 0
                    var r: Float = 0
                    for c in 0..<sourceChannels {
                        let v = interleaved[f * sourceChannels + c]
                        if c % 2 == 0 { l += v } else { r += v }
                    }
                    let half = Float(sourceChannels / 2)
                    out[f * 2] = l / max(half, 1)
                    out[f * 2 + 1] = r / max(Float(sourceChannels - sourceChannels / 2), 1)
                }
                return (out, 2)
            }
            return (interleaved, 2)
        default:
            throw EngineError.importFailed("unreachable mix channel policy branch")
        }
    }
}

// MARK: - Float32 WAV (staging mix format — full decode precision, no 16-bit
// quantization before separation; PCMWaveWriter/PCMWaveReader stay untouched —
// other lanes depend on their exact mono/16-bit semantics).

public enum PCMF32Wav {
    public enum WavError: Error, Sendable {
        case notRIFF(String)
        case unsupportedFormat(String)
        case truncated(String)
    }

    /// Writes channel-interleaved float32 PCM WAV (WAVE_FORMAT_IEEE_FLOAT=3).
    public static func write(url: URL, frames: [Float], sampleRate: Int, channels: Int) throws {
        guard channels == 1 || channels == 2 else {
            throw WavError.unsupportedFormat("staging mix supports 1–2 channels, got \(channels)")
        }
        guard !frames.isEmpty else { throw WavError.truncated("no frames to write") }
        for (i, v) in frames.enumerated() where !v.isFinite {
            throw WavError.truncated("non-finite sample at \(i)")
        }
        let dataLen = frames.count * 4
        var d = Data()
        func ascii(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(36 + dataLen)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(3); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * channels * 4)); u16(UInt16(channels * 4)); u16(32)
        ascii("data"); u32(UInt32(dataLen))
        d.reserveCapacity(d.count + dataLen)
        frames.withUnsafeBufferPointer { buf in
            d.append(contentsOf: UnsafeBufferPointer(start: UnsafeRawPointer(buf.baseAddress!).assumingMemoryBound(to: UInt8.self), count: dataLen))
        }
        try d.write(to: url)
    }

    /// Channel-preserving read (unlike Pitch/PCMWaveReader, which mono-downmixes
    /// for the pitch path). Returns interleaved float frames.
    public static func read(url: URL) throws -> (frames: [Float], sampleRate: Int, channels: Int) {
        let bytes = try Array(Data(contentsOf: url))
        guard bytes.count >= 12,
              String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE" else {
            throw WavError.notRIFF("missing RIFF/WAVE header")
        }
        var fmt: UInt16 = 0
        var channels = 0
        var sampleRate = 0
        var bits = 0
        var payload: ArraySlice<UInt8>?
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = String(bytes: bytes[offset..<offset + 4], encoding: .ascii) ?? ""
            let size = Int(readU32(bytes[...], offset + 4))
            let body = offset + 8
            guard body + size <= bytes.count else {
                throw WavError.truncated("chunk '\(id)' claims \(size) bytes past EOF")
            }
            switch id {
            case "fmt ":
                fmt = readU16(bytes[...], body)
                channels = Int(readU16(bytes[...], body + 2))
                sampleRate = Int(readU32(bytes[...], body + 4))
                bits = Int(readU16(bytes[...], body + 14))
            case "data":
                payload = bytes[body..<(body + size)]
            default:
                break
            }
            offset = body + size + (size & 1)
        }
        guard let payload, sampleRate > 0, channels >= 1 else {
            throw WavError.truncated("missing fmt/data chunks")
        }
        guard fmt == 3 || (fmt == 0xFFFE && bits == 32) else {
            throw WavError.unsupportedFormat("staging reader expects float32 WAV, got fmt \(fmt) bits \(bits)")
        }
        guard bits == 32 else {
            throw WavError.unsupportedFormat("bits/sample \(bits)")
        }
        let bytesPerFrame = channels * 4
        let frames = payload.count / bytesPerFrame
        var out = [Float](repeating: 0, count: frames * channels)
        let base = payload.startIndex
        for i in 0..<(frames * channels) {
            let p = base + i * 4
            out[i] = Float(bitPattern: readU32(payload, p))
        }
        return (out, sampleRate, channels)
    }

    private static func readU16(_ b: ArraySlice<UInt8>, _ i: Int) -> UInt16 {
        UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }

    private static func readU32(_ b: ArraySlice<UInt8>, _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}

// MARK: - Decode seam (portable; Apple conformer = AVAudioFileDecoder, ImportKit)

public protocol AudioDecoding {
    /// Decodes the container at `source`, normalizes per DecodePolicy
    /// (44.1 kHz, mix channels ∈ {1, 2}), writes the staging mix WAV into
    /// `workDir`, and returns its descriptor (`DecodedAudio.url` = mix file).
    /// Throws EngineError.unsupportedFormat for undecodable containers.
    func decodeToMix(source: URL, workDir: URL) throws -> DecodedAudio
}

public extension AudioDecoding {
    /// Shared normalization + staging write for all conformers: the conformer
    /// returns channel-interleaved SOURCE-rate samples; this applies the mix
    /// channel policy, resamples to 44.1 kHz (per channel, deterministic sinc —
    /// AudioResampler), writes the staging WAV, and returns the descriptor.
    /// Apple conformers MAY replace the resample with AVAudioConverter upstream
    /// but must still land here with source-rate samples for one code path.
    ///
    /// THIS IS THE WHOLE-BUFFER REFERENCE PATH — P-210 keeps it in the tree
    /// unchanged, because the streaming path's output is asserted BYTE-IDENTICAL
    /// to it (the Linux tests) and the CI-proven path must not be destabilised.
    static func normalizeAndStage(_ decoded: (samples: [Float], sampleRate: Int, channels: Int),
                                  workDir: URL) throws -> DecodedAudio {
        guard decoded.sampleRate > 0 else {
            throw EngineError.unsupportedFormat("invalid source sample rate \(decoded.sampleRate)")
        }
        let (mix, mixChannels) = try DecodePolicy.applyMixChannelPolicy(
            interleaved: decoded.samples, sourceChannels: decoded.channels)

        let framesIn = mix.count / mixChannels
        var chans: [[Float]] = []
        for c in 0..<mixChannels {
            let mono = (0..<framesIn).map { mix[$0 * mixChannels + c] }
            // Per-channel sinc resample (deterministic); identical input length
            // ⇒ identical output length across channels. The buffer below is
            // sized from the RESAMPLED length (an earlier draft sized it from
            // framesIn — trailing zeros + wrong duration_s; caught by the
            // 48k→44.1k staging test).
            chans.append(decoded.sampleRate == DecodePolicy.targetSampleRate
                         ? mono
                         : AudioResampler.resample(samples: mono, sourceRate: decoded.sampleRate,
                                                   targetRate: DecodePolicy.targetSampleRate))
        }
        let framesOut = chans[0].count
        var out = [Float](repeating: 0, count: framesOut * mixChannels)
        for c in 0..<mixChannels {
            let chData = chans[c]
            for f in 0..<framesOut {
                out[f * mixChannels + c] = chData[f]
            }
        }

        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let mixURL = workDir.appendingPathComponent("staging-mix-44k1.f32.wav")
        try? FileManager.default.removeItem(at: mixURL)
        try PCMF32Wav.write(url: mixURL, frames: out,
                            sampleRate: DecodePolicy.targetSampleRate, channels: mixChannels)
        let outFrames = out.count / mixChannels
        return DecodedAudio(url: mixURL, sampleRate: DecodePolicy.targetSampleRate,
                            channels: mixChannels,
                            duration_s: Double(outFrames) / Double(DecodePolicy.targetSampleRate))
    }
    /// The STREAMING normalization + staging (P-210): the SAME policy and the
    /// SAME bytes as `normalizeAndStage`, but the source samples arrive in
    /// chunks and the staged mix is written AS they are produced — the song is
    /// never held in memory.
    ///
    /// `produce` returns the next channel-interleaved SOURCE-rate chunk, or
    /// `nil` when the source is exhausted. On ANY failure the partial staging
    /// file is removed (C-2.2: a failed or cancelled import leaves no residue).
    static func normalizeAndStageStreaming(sourceSampleRate: Int,
                                           sourceChannels: Int,
                                           workDir: URL,
                                           produce: () throws -> [Float]?) throws -> DecodedAudio {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let mixURL = workDir.appendingPathComponent("staging-mix-44k1.f32.wav")
        try? FileManager.default.removeItem(at: mixURL)
        let stager = try StreamingMixStager(url: mixURL,
                                            sourceSampleRate: sourceSampleRate,
                                            sourceChannels: sourceChannels)
        do {
            while let chunk = try produce() {
                guard !chunk.isEmpty else { continue }
                try stager.push(interleaved: chunk)
            }
            return try stager.finish()
        } catch {
            stager.abort()
            throw error
        }
    }
}

/// Channel-preserving WAV source decoder (the Linux-testable conformer; MP3/
/// FLAC/ALAC sources decode through AVAudioFileDecoder on Apple — CI proves
/// the seam contract for all four container formats there).
public struct WavSourceDecoder: AudioDecoding {
    public init() {}

    /// The STREAMING decode (P-210): the WAV is read window-by-window from a
    /// file handle (the old path did `Data(contentsOf:)` on the whole file) and
    /// staged as it goes. The staged bytes are identical to the whole-buffer
    /// path's (asserted in the Linux tests).
    public func decodeToMix(source: URL, workDir: URL) throws -> DecodedAudio {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw EngineError.importFailed("input file does not exist at \(source.path)")
        }
        let reader = try WavFileReader(url: source)
        guard reader.totalFrames > 0, reader.channels >= 1 else {
            throw EngineError.unsupportedFormat(
                "empty decode (\(reader.totalFrames) frames, \(reader.channels) ch) for \(source.lastPathComponent)")
        }
        var frame = 0
        return try Self.normalizeAndStageStreaming(
            sourceSampleRate: reader.sampleRate,
            sourceChannels: reader.channels,
            workDir: workDir) {
                guard frame < reader.totalFrames else { return nil }
                let count = min(8192, reader.totalFrames - frame)
                let chunk = try reader.read(startFrame: frame, frameCount: count)
                frame += count
                return chunk
            }
    }

    /// Channel-preserving PCM16/float32 WAV parse → interleaved Float samples
    /// at the SOURCE rate/channels (no policy here — normalizeAndStage owns it).
    ///
    /// THIS IS THE WHOLE-FILE REFERENCE PARSE (P-210): the streaming decoder
    /// uses `WavFileReader` instead, and the tests assert that both produce the
    /// same staged bytes. Kept as the reference implementation.
    func parseWav(_ bytes: [UInt8]) throws -> (samples: [Float], sampleRate: Int, channels: Int) {
        guard bytes.count >= 12,
              String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE" else {
            throw EngineError.unsupportedFormat("not a RIFF/WAVE file")
        }
        var fmt: UInt16 = 0
        var channels = 0
        var sampleRate = 0
        var bits = 0
        var payload: ArraySlice<UInt8>?
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = String(bytes: bytes[offset..<offset + 4], encoding: .ascii) ?? ""
            let size = Int(readU32(bytes, offset + 4))
            let body = offset + 8
            guard body + size <= bytes.count else {
                throw EngineError.importFailed("truncated WAV chunk '\(id)'")
            }
            switch id {
            case "fmt ":
                fmt = readU16(bytes, body)
                channels = Int(readU16(bytes, body + 2))
                sampleRate = Int(readU32(bytes, body + 4))
                bits = Int(readU16(bytes, body + 14))
            case "data":
                payload = bytes[body..<(body + size)]
            default:
                break
            }
            offset = body + size + (size & 1)
        }
        guard let payload, sampleRate > 0, channels >= 1 else {
            throw EngineError.importFailed("WAV missing fmt/data chunks")
        }
        guard fmt == 1 || fmt == 3 || (fmt == 0xFFFE && bits == 32) else {
            throw EngineError.unsupportedFormat("WAV audio format \(fmt) (need PCM=1 or float=3)")
        }
        guard bits == 16 || bits == 32 else {
            throw EngineError.unsupportedFormat("bits/sample \(bits) (need 16 or 32)")
        }
        let isFloat = fmt == 3 || (fmt == 0xFFFE && bits == 32)
        let bytesPerSample = bits / 8
        let bytesPerFrame = channels * bytesPerSample
        let frames = payload.count / bytesPerFrame
        var out = [Float](repeating: 0, count: frames * channels)
        let base = payload.startIndex
        for i in 0..<(frames * channels) {
            let p = base + i * bytesPerSample
            if isFloat {
                out[i] = Float(bitPattern: readU32(bytes, p))
            } else {
                out[i] = Float(Int16(bitPattern: readU16(bytes, p))) / 32768.0
            }
        }
        return (out, sampleRate, channels)
    }

    private func readU16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }

    private func readU32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}
