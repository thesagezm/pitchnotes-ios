import Foundation

// P-210 · Streaming decode→stage (PAUL lane, portable core — Linux-tested).
//
// WHY THIS EXISTS: P-209 removed the O(song) term from the SEPARATION stage
// (the staged mix is read window-by-window; the stems are written as they are
// finalised). The DECODE stage still held the song — and held it SEVERAL times:
//
//   * the Apple decoder allocated a whole-file AVAudioPCMBuffer and then a
//     whole-file INTERLEAVED copy (for a 4-minute stereo 44.1 kHz song: ≈ 85 MB
//     each),
//   * `AudioDecoding.normalizeAndStage` copied the mix again (channel policy),
//     split it into per-channel arrays, resampled each into a whole-song array
//     and interleaved the result into ANOTHER whole-song array,
//   * `PCMF32Wav.write` built the whole staging file as one in-memory `Data`,
//   * and the tuning estimator read the staged mix back WHOLE (file `Data` +
//     samples + a mono fold + a 16 kHz copy) just to estimate ±50 cents.
//
// Every one of those terms scales with song length. This file replaces them
// with bounded, streaming seams:
//
//   WavFileReader        → reads a WAV file frame-by-frame from a file HANDLE
//                          (header parsed by scanning chunks; the file is
//                          never loaded)
//   StreamingAudioResampler → the SAME Kaiser-windowed sinc as
//                          `AudioResampler.resample`, but stateful: it keeps a
//                          sliding input window and emits outputs as soon as
//                          their input window is complete
//   PCMF32StreamWriter   → writes the staging mix as it is produced (the
//                          header sizes are patched in `finish()`)
//   StreamingMixStager   → decode-chunks → channel policy → resample → write,
//                          with a retained-frame bound that does not depend on
//                          the song length
//
// THE WHOLE-BUFFER PATH STAYS AS THE REFERENCE IMPLEMENTATION (the P-209
// pattern): `normalizeAndStage` / `PCMF32Wav.write` / `PCMF32Wav.read` are
// untouched, and the Linux tests assert that the streamed staging WAV is
// BYTE-IDENTICAL to the whole-buffer one and that the streamed 16 kHz mono
// signal is BIT-IDENTICAL to the whole-file one. The CI-proven path is not
// destabilised by this refactor.
//
// The A14 DEVICE peak-RSS number is P-603's job: this is a code change, not a
// device measurement. What it removes is the O(song) TERM.

// MARK: - Streaming resampler (stateful, bit-identical to AudioResampler)

/// The windowed-sinc resampler of `AudioResampler` in streaming form.
///
/// The kernel, the cutoff, the Kaiser window and the ACCUMULATION ORDER are
/// identical to `AudioResampler.resample`, so the output is BIT-IDENTICAL to
/// the whole-buffer path for the same input. The difference is only in WHEN
/// each output becomes computable:
///
///   * output `k` reads the input window `[ceil(tau - halfWidth), floor(tau +
///     halfWidth)]` around `tau = k · sourceRate / targetRate`,
///   * it can be emitted as soon as the input up to `floor(tau + halfWidth)` is
///     available (the window's upper end is then final — the whole-buffer path
///     clamps it to `n - 1` only at the very end of the signal),
///   * `finish()` flushes the tail with that final clamp and emits exactly
///     `Int(Double(totalInput) · ratio)` outputs — the same count the
///     whole-buffer path produces.
///
/// Retained memory: the sliding input window (≈ `halfWidth` samples per side)
/// plus the caller's chunk — independent of the song length.
public final class StreamingAudioResampler {

    /// Kernel half-width in input samples (mirror of `AudioResampler`).
    public let halfWidth: Double
    public let sourceRate: Int
    public let targetRate: Int

    private let ratio: Double
    private let fc: Double
    private let norm: Double
    private let isPassthrough: Bool

    /// Pending input samples; `pendingStart` is the GLOBAL index of `pending[0]`.
    private var pending: [Float] = []
    private var pendingStart = 0
    /// Total input samples seen so far (= `n` once finished).
    private var totalInput = 0
    /// The next output index to compute.
    private var nextOutput = 0
    private var finished = false

    public init(sourceRate: Int, targetRate: Int) {
        precondition(sourceRate > 0 && targetRate > 0, "sample rates must be positive")
        self.sourceRate = sourceRate
        self.targetRate = targetRate
        self.isPassthrough = sourceRate == targetRate
        if isPassthrough {
            self.ratio = 1.0
            self.fc = 0
            self.halfWidth = 0
            self.norm = 0
        } else {
            self.ratio = Double(targetRate) / Double(sourceRate)
            // Cutoff in cycles per INPUT sample: min(source, target) Nyquist × 0.9.
            let cutoffHz = AudioResamplerCutoff.cutoffFraction * 0.5 * Double(min(sourceRate, targetRate))
            self.fc = cutoffHz / Double(sourceRate)
            self.halfWidth = AudioResamplerCutoff.zeroCrossings / max(self.fc, 1e-9)
            self.norm = 1.0 / AudioResampler.besselI0(AudioResamplerCutoff.kaiserBeta)
        }
    }

    /// Appends source-rate samples and returns every output that became
    /// computable. The returned count does NOT depend on how the input was
    /// chunked.
    public func push(_ samples: [Float]) -> [Float] {
        guard !finished else { return [] }
        guard !isPassthrough else {
            // The whole-buffer path short-circuits an equal-rate resample by
            // copying the input through unchanged.
            totalInput += samples.count
            nextOutput += samples.count
            return samples
        }
        pending.append(contentsOf: samples)
        totalInput += samples.count
        return emitAvailable(final: false)
    }

    /// Flushes the tail: the final input clamp (`n - 1`) is applied and exactly
    /// `Int(Double(totalInput) · ratio)` outputs are produced.
    public func finish() -> [Float] {
        guard !finished else { return [] }
        finished = true
        guard !isPassthrough else { return [] }
        return emitAvailable(final: true)
    }

    /// Input samples currently retained (the sliding window) — the memory bound.
    public var retainedSamples: Int { pending.count }

    /// Computes the outputs whose input window is available.
    ///
    /// `final` = true means the total input count is known, so the whole-buffer
    /// path's `hi = min(n - 1, …)` clamp applies and the output count is exact.
    private func emitAvailable(final: Bool) -> [Float] {
        var out: [Float] = []
        let n = totalInput
        guard n > 0 else { return out }
        // The final output count (the whole-buffer path's `outCount`).
        let finalCount = Int(Double(n) * ratio)
        while true {
            let k = nextOutput
            guard k < finalCount else { break }
            let tau = Double(k) * Double(sourceRate) / Double(targetRate)
            let hiFull = Int(floor(tau + halfWidth))
            if !final {
                // The whole input window must be present, and the output must
                // still be inside the (not yet final) output count.
                guard hiFull <= n - 1 else { break }
                guard k < Int(Double(n) * ratio) else { break }
            }
            let lo = max(0, Int(ceil(tau - halfWidth)))
            let hi = final ? min(n - 1, hiFull) : hiFull
            var acc: Double = 0
            if lo <= hi {
                for m in lo...hi {
                    let x = tau - Double(m)
                    let u = x / halfWidth
                    if abs(u) >= 1.0 { continue }
                    let window = AudioResampler.besselI0(
                        AudioResamplerCutoff.kaiserBeta * (1.0 - u * u).squareRoot()) * norm
                    // Kernel h(x) = 2·fc·sinc(2·fc·x)·window, sinc(y)=sin(πy)/(πy);
                    // equivalently sin(2πfc·x)/(πx) with the x→0 limit 2·fc.
                    let sincArg = 2.0 * .pi * fc * x
                    let kernel: Double
                    if abs(x) < 1e-12 {
                        kernel = 2.0 * fc
                    } else {
                        kernel = sin(sincArg) / (.pi * x)
                    }
                    acc += Double(sample(at: m)) * kernel * window
                }
            }
            out.append(Float(acc))
            nextOutput = k + 1
            // The next output's window starts at or after this one's, so the
            // samples below `lo` are never needed again.
            if lo > pendingStart {
                pending.removeFirst(lo - pendingStart)
                pendingStart = lo
            }
        }
        return out
    }

    /// Global-indexed access into the pending window.
    private func sample(at index: Int) -> Float {
        let offset = index - pendingStart
        precondition(offset >= 0 && offset < pending.count,
                     "streaming resampler: sample \(index) is outside the retained window")
        return pending[offset]
    }
}

/// The kernel constants of `AudioResampler` (mirrored here so the streaming
/// resampler and the whole-buffer one cannot drift apart).
enum AudioResamplerCutoff {
    static let zeroCrossings = 16.0
    static let kaiserBeta = 8.6
    static let cutoffFraction = 0.90
}

// MARK: - Streaming staging writer (float32 WAV)

/// Writes the staging mix as it is produced.
///
/// The bytes are IDENTICAL to `PCMF32Wav.write` (same header layout, same raw
/// float32 payload), so the staged mix file does not change when the import
/// path moves to streaming.
///
/// The header is written with placeholder sizes and patched in `finish()` — a
/// file that was never finished is a partial file, and `abort()` removes it
/// (C-2.2: a failed or cancelled import leaves no residue).
public final class PCMF32StreamWriter {

    public let url: URL
    public let sampleRate: Int
    public let outputChannels: Int

    private let handle: FileHandle
    private let lock = NSLock()
    private var framesWritten = 0
    private var finished = false

    public init(url: URL, sampleRate: Int = DecodePolicy.targetSampleRate,
                outputChannels: Int) throws {
        guard outputChannels == 1 || outputChannels == 2 else {
            throw PCMF32Wav.WavError.unsupportedFormat(
                "staging mix supports 1–2 channels, got \(outputChannels)")
        }
        self.url = url
        self.sampleRate = sampleRate
        self.outputChannels = outputChannels
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw PCMF32Wav.WavError.truncated("cannot create \(url.path)")
        }
        let h: FileHandle
        do {
            h = try FileHandle(forWritingTo: url)
        } catch {
            throw PCMF32Wav.WavError.truncated(
                "cannot open \(url.path) for writing: \(error.localizedDescription)")
        }
        self.handle = h
        // Placeholder header (44 bytes) — the sizes are patched in finish().
        var header = Data()
        func ascii(_ s: String) { header.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        let bytesPerSample = 4
        let byteRate = sampleRate * outputChannels * bytesPerSample
        ascii("RIFF"); u32(0); ascii("WAVE")
        ascii("fmt "); u32(16); u16(3); u16(UInt16(outputChannels))
        u32(UInt32(sampleRate)); u32(UInt32(byteRate))
        u16(UInt16(outputChannels * bytesPerSample)); u16(32)
        ascii("data"); u32(0)
        try handle.write(contentsOf: header)
    }

    deinit {
        try? handle.close()
    }

    /// Appends interleaved frames (frames × `outputChannels`).
    public func append(frames: [Float]) throws {
        guard !frames.isEmpty else { return }
        guard frames.count % outputChannels == 0 else {
            throw PCMF32Wav.WavError.unsupportedFormat(
                "staging frames are not frame-aligned (\(frames.count) samples)")
        }
        lock.lock()
        defer { lock.unlock() }
        guard !finished else {
            throw PCMF32Wav.WavError.truncated("staging writer already finished")
        }
        for (i, v) in frames.enumerated() where !v.isFinite {
            throw PCMF32Wav.WavError.truncated(
                "non-finite sample at \(framesWritten * outputChannels + i)")
        }
        // The payload is written as RAW float32 bytes — exactly what
        // `PCMF32Wav.write` writes (same bytes, same order).
        var payload = Data()
        payload.reserveCapacity(frames.count * 4)
        frames.withUnsafeBufferPointer { buf in
            payload.append(contentsOf: UnsafeBufferPointer(
                start: UnsafeRawPointer(buf.baseAddress!).assumingMemoryBound(to: UInt8.self),
                count: frames.count * 4))
        }
        do {
            try handle.write(contentsOf: payload)
        } catch {
            throw PCMF32Wav.WavError.truncated(
                "staging write failed at frame \(framesWritten): \(error.localizedDescription)")
        }
        framesWritten += frames.count / outputChannels
    }

    /// Patches the RIFF/data sizes and closes the file. The file is COMPLETE
    /// only after this returns.
    public func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        let dataBytes = UInt32(framesWritten * outputChannels * 4)
        func u32Data(_ v: UInt32) -> Data {
            var d = Data()
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
            return d
        }
        do {
            // The RIFF chunk size lives at offset 4 and the data chunk size at
            // offset 40 — they are patched SEPARATELY (one contiguous block
            // would overwrite the "WAVE"/"fmt " identifiers).
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: u32Data(36 &+ dataBytes))
            try handle.seek(toOffset: 40)
            try handle.write(contentsOf: u32Data(dataBytes))
            try handle.synchronize()
            try handle.close()
        } catch {
            throw PCMF32Wav.WavError.truncated(
                "staging finalise failed for \(url.lastPathComponent): \(error.localizedDescription)")
        }
        finished = true
    }

    /// Closes and REMOVES the partial file (C-2.2: no residue).
    public func abort() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    /// Frames written so far (test/diagnostic helper).
    public var writtenFrames: Int {
        lock.lock(); defer { lock.unlock() }; return framesWritten
    }
}

// MARK: - The streaming stager (decode chunks → policy → resample → write)

/// Normalizes and stages a mix WITHOUT holding the song in memory.
///
/// The seam mirrors `AudioDecoding.normalizeAndStage` exactly: the same D-8
/// channel policy (> 2 channels mean-downmix to stereo), the same per-channel
/// sinc resample to 44.1 kHz, the same interleaved staging WAV — but the
/// source samples arrive in chunks and the staged mix leaves as it is produced.
///
/// The retained-frame bound (`maxRetainedFrames`) is the memory claim: it does
/// NOT depend on the song length.
public final class StreamingMixStager {

    public let url: URL
    public let sourceSampleRate: Int
    public let sourceChannels: Int
    public let mixChannels: Int

    private let writer: PCMF32StreamWriter
    /// One resampler per mix channel — empty when the source rate already is
    /// the target rate (the whole-buffer path short-circuits that case).
    private var resamplers: [StreamingAudioResampler] = []
    /// Per-channel carry-over when the channels emit different counts.
    private var channelCarry: [[Float]] = []
    private var stagedFrames = 0
    private var maxRetainedFrames = 0
    private var finished = false

    public init(url: URL, sourceSampleRate: Int, sourceChannels: Int) throws {
        self.url = url
        self.sourceSampleRate = sourceSampleRate
        self.sourceChannels = sourceChannels
        self.mixChannels = try DecodePolicy.mixChannels(sourceChannels: sourceChannels)
        self.writer = try PCMF32StreamWriter(url: url,
                                             sampleRate: DecodePolicy.targetSampleRate,
                                             outputChannels: mixChannels)
        if sourceSampleRate != DecodePolicy.targetSampleRate {
            self.resamplers = (0..<mixChannels).map { _ in
                StreamingAudioResampler(sourceRate: sourceSampleRate,
                                        targetRate: DecodePolicy.targetSampleRate)
            }
            self.channelCarry = (0..<mixChannels).map { _ in [] }
        }
    }

    /// Pushes one chunk of channel-interleaved SOURCE-rate samples.
    public func push(interleaved: [Float]) throws {
        guard !finished else { throw PCMF32Wav.WavError.truncated("stager already finished") }
        guard !interleaved.isEmpty else { return }
        guard interleaved.count % sourceChannels == 0 else {
            throw EngineError.importFailed(
                "decode chunk is not frame-aligned (\(interleaved.count) samples, "
                + "\(sourceChannels) channels)")
        }
        let frames = interleaved.count / sourceChannels

        // D-8 channel policy — per frame, so chunking cannot change it.
        var perChannel: [[Float]] = (0..<mixChannels).map { _ in
            [Float](repeating: 0, count: frames)
        }
        if sourceChannels == mixChannels {
            for f in 0..<frames {
                for c in 0..<mixChannels {
                    perChannel[c][f] = interleaved[f * sourceChannels + c]
                }
            }
        } else {
            // > 2 channels: pair means (the same math as
            // `DecodePolicy.applyMixChannelPolicy`, in the same order).
            let half = Float(sourceChannels / 2)
            let rightDenom = max(Float(sourceChannels - sourceChannels / 2), 1)
            for f in 0..<frames {
                var l: Float = 0
                var r: Float = 0
                for c in 0..<sourceChannels {
                    let v = interleaved[f * sourceChannels + c]
                    if c % 2 == 0 { l += v } else { r += v }
                }
                perChannel[0][f] = l / max(half, 1)
                perChannel[1][f] = r / rightDenom
            }
        }

        if resamplers.isEmpty {
            // No resampling: the staged frames are the source frames.
            var interleavedOut = [Float](repeating: 0, count: frames * mixChannels)
            for f in 0..<frames {
                for c in 0..<mixChannels {
                    interleavedOut[f * mixChannels + c] = perChannel[c][f]
                }
            }
            try writer.append(frames: interleavedOut)
            stagedFrames += frames
        } else {
            var produced: [[Float]] = []
            for c in 0..<mixChannels {
                var out = resamplers[c].push(perChannel[c])
                if !channelCarry[c].isEmpty {
                    out.insert(contentsOf: channelCarry[c], at: 0)
                    channelCarry[c] = []
                }
                produced.append(out)
            }
            // Interleave the common count; the remainder is carried (the
            // channels emit the same count in practice — identical input
            // lengths — but the carry keeps the seam safe).
            let common = produced.map { $0.count }.min() ?? 0
            if common > 0 {
                var interleavedOut = [Float](repeating: 0, count: common * mixChannels)
                for f in 0..<common {
                    for c in 0..<mixChannels {
                        interleavedOut[f * mixChannels + c] = produced[c][f]
                    }
                }
                try writer.append(frames: interleavedOut)
                stagedFrames += common
            }
            for c in 0..<mixChannels where produced[c].count > common {
                channelCarry[c] = Array(produced[c][common...])
            }
        }

        // The memory claim: source frames retained at once (the chunk in
        // flight + the resamplers' sliding windows). Independent of length.
        let retained = frames + resamplers.reduce(0) { $0 + $1.retainedSamples }
        maxRetainedFrames = max(maxRetainedFrames, retained)
    }

    /// Flushes the resamplers' tails, finishes the file and returns the
    /// descriptor of the staged mix.
    @discardableResult
    public func finish() throws -> DecodedAudio {
        guard !finished else {
            throw PCMF32Wav.WavError.truncated("stager already finished")
        }
        finished = true
        if !resamplers.isEmpty {
            var produced: [[Float]] = []
            for c in 0..<mixChannels {
                var out = resamplers[c].finish()
                if !channelCarry[c].isEmpty {
                    out.insert(contentsOf: channelCarry[c], at: 0)
                    channelCarry[c] = []
                }
                produced.append(out)
            }
            let common = produced.map { $0.count }.min() ?? 0
            if common > 0 {
                var interleavedOut = [Float](repeating: 0, count: common * mixChannels)
                for f in 0..<common {
                    for c in 0..<mixChannels {
                        interleavedOut[f * mixChannels + c] = produced[c][f]
                    }
                }
                try writer.append(frames: interleavedOut)
                stagedFrames += common
            }
            for c in 0..<mixChannels where produced[c].count > common {
                channelCarry[c] = Array(produced[c][common...])
            }
            if channelCarry.contains(where: { !$0.isEmpty }) {
                // The channels must agree on the staged length; a mismatch
                // would mean a misaligned resampler — fail loudly.
                throw PCMF32Wav.WavError.truncated(
                    "streaming stage produced mismatched channel lengths")
            }
        }
        try writer.finish()
        return DecodedAudio(url: url, sampleRate: DecodePolicy.targetSampleRate,
                            channels: mixChannels,
                            duration_s: Double(stagedFrames) / Double(DecodePolicy.targetSampleRate))
    }

    /// Aborts the staging write and removes the partial file (C-2.2).
    public func abort() {
        guard !finished else { return }
        finished = true
        writer.abort()
    }

    /// The largest number of SOURCE frames retained at once — the memory
    /// bound. It does not grow with the song length.
    public var retainedFrameBound: Int { maxRetainedFrames }

    /// Frames staged so far.
    public var stagedFrameCount: Int { stagedFrames }
}

// MARK: - File-backed WAV reader (header parsed, file never loaded)

/// Reads a WAV file frame-by-frame from a file HANDLE.
///
/// The header is parsed by scanning the RIFF chunks with the handle, so the
/// file is never loaded into memory (the old path did `Data(contentsOf:)` on
/// the whole file — an O(song) term).
public final class WavFileReader {

    public let url: URL
    public let sampleRate: Int
    public let channels: Int
    public let bitsPerSample: Int
    public let totalFrames: Int
    public let isFloat: Bool

    private let dataOffset: UInt64
    private let bytesPerFrame: Int
    private let handle: FileHandle

    public init(url: URL) throws {
        self.url = url
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw EngineError.importFailed("no such file: \(url.path)")
        }
        let h: FileHandle
        do {
            h = try FileHandle(forReadingFrom: url)
        } catch {
            throw EngineError.importFailed(
                "cannot open \(url.path): \(error.localizedDescription)")
        }
        self.handle = h

        let header = try Self.parseHeader(handle: h)
        self.dataOffset = header.dataOffset
        self.channels = header.channels
        self.sampleRate = header.sampleRate
        self.bitsPerSample = header.bitsPerSample
        self.isFloat = header.isFloat
        self.bytesPerFrame = header.channels * (header.bitsPerSample / 8)
        self.totalFrames = header.dataLength / bytesPerFrame
    }

    deinit {
        try? handle.close()
    }

    /// Reads `frameCount` frames starting at `startFrame` (channel-interleaved
    /// floats at the file's native rate).
    public func read(startFrame: Int, frameCount: Int) throws -> [Float] {
        guard startFrame >= 0, frameCount >= 0,
              startFrame + frameCount <= totalFrames else {
            throw EngineError.importFailed(
                "WAV read out of range: frame \(startFrame)+\(frameCount) of \(totalFrames)")
        }
        if frameCount == 0 { return [] }
        let byteCount = frameCount * bytesPerFrame
        do {
            try handle.seek(toOffset: dataOffset + UInt64(startFrame * bytesPerFrame))
            guard let data = try handle.read(upToCount: byteCount), data.count == byteCount else {
                throw EngineError.importFailed(
                    "WAV ended before frame \(startFrame + frameCount)/\(totalFrames)")
            }
            var out = [Float](repeating: 0, count: frameCount * channels)
            let base = data.startIndex
            if isFloat {
                for i in 0..<out.count {
                    let p = base + i * 4
                    let bits = UInt32(data[p]) | UInt32(data[p + 1]) << 8
                        | UInt32(data[p + 2]) << 16 | UInt32(data[p + 3]) << 24
                    out[i] = Float(bitPattern: bits)
                }
            } else {
                for i in 0..<out.count {
                    let p = base + i * 2
                    let raw = Int16(bitPattern: UInt16(data[p]) | UInt16(data[p + 1]) << 8)
                    out[i] = Float(raw) / 32768.0
                }
            }
            return out
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.importFailed(
                "WAV read failed at frame \(startFrame): \(error.localizedDescription)")
        }
    }

    private static func parseHeader(handle: FileHandle) throws
        -> (dataOffset: UInt64, dataLength: Int, channels: Int, sampleRate: Int,
            bitsPerSample: Int, isFloat: Bool) {
        func readAt(_ offset: UInt64, _ count: Int) throws -> [UInt8] {
            try handle.seek(toOffset: offset)
            guard let d = try handle.read(upToCount: count), d.count == count else {
                throw EngineError.importFailed("WAV header ended at offset \(offset)")
            }
            return [UInt8](d)
        }
        let riff = try readAt(0, 12)
        guard String(bytes: riff[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: riff[8..<12], encoding: .ascii) == "WAVE" else {
            throw EngineError.importFailed("not a RIFF/WAVE file")
        }
        var offset: UInt64 = 12
        var fmt: UInt16 = 0
        var channels = 0
        var sampleRate = 0
        var bits = 0
        while true {
            let chunk = try readAt(offset, 8)
            let id = String(bytes: chunk[0..<4], encoding: .ascii) ?? ""
            let size = Int(UInt32(chunk[4]) | UInt32(chunk[5]) << 8
                           | UInt32(chunk[6]) << 16 | UInt32(chunk[7]) << 24)
            let body = offset + 8
            switch id {
            case "fmt ":
                let f = try readAt(body, 16)
                fmt = UInt16(f[0]) | UInt16(f[1]) << 8
                channels = Int(UInt16(f[2]) | UInt16(f[3]) << 8)
                sampleRate = Int(UInt32(f[4]) | UInt32(f[5]) << 8
                                 | UInt32(f[6]) << 16 | UInt32(f[7]) << 24)
                bits = Int(UInt16(f[14]) | UInt16(f[15]) << 8)
            case "data":
                let isFloat = fmt == 3 || (fmt == 0xFFFE && bits == 32)
                guard fmt == 1 || isFloat else {
                    throw EngineError.importFailed(
                        "WAV audio format \(fmt) (need PCM=1 or float=3)")
                }
                guard bits == 16 || bits == 32 else {
                    throw EngineError.importFailed("bits/sample \(bits) (need 16 or 32)")
                }
                guard channels >= 1 else {
                    throw EngineError.importFailed("WAV has no channels")
                }
                return (body, size, channels, sampleRate, bits, isFloat)
            default:
                break
            }
            offset = body + UInt64(size) + UInt64(size & 1)
        }
    }
}

// MARK: - The tuning estimator's streaming read

public extension PCMF32Wav {

    /// The staged mix → MONO 16 kHz, read FILE-BACKED and streamed.
    ///
    /// The old path read the whole staged file (`Data(contentsOf:)` + the whole
    /// sample array), folded it to mono (another whole-song array) and
    /// resampled it (another). This reads the file in windows, folds each
    /// window and resamples it on the fly — the RESULT is BIT-IDENTICAL to the
    /// whole-file path (the fold is per frame and the resampler is bit-
    /// identical), but the transient memory is a window instead of the song.
    ///
    /// At 16 kHz mono the result itself is ~15 MB for a 4-minute song — small
    /// enough to keep in memory (the estimator needs the whole signal for its
    /// window selection).
    static func mono16k(url: URL, windowFrames: Int = 8192) throws -> [Float] {
        let reader = try WavFileReader(url: url)
        guard reader.totalFrames > 0 else { throw WavError.truncated("empty staging mix") }
        let resampler = StreamingAudioResampler(sourceRate: reader.sampleRate,
                                                targetRate: SwiftF0Spec.sampleRate)
        var out: [Float] = []
        out.reserveCapacity(reader.totalFrames * reader.sampleRate / SwiftF0Spec.sampleRate + 1)
        var frame = 0
        while frame < reader.totalFrames {
            let count = min(windowFrames, reader.totalFrames - frame)
            let raw = try reader.read(startFrame: frame, frameCount: count)
            // Channel-mean fold — the same accumulation order as the
            // whole-file path (`folded[i / ch] += v / Float(ch)`).
            var mono = [Float](repeating: 0, count: count)
            for (i, v) in raw.enumerated() {
                mono[i / reader.channels] += v / Float(reader.channels)
            }
            out.append(contentsOf: resampler.push(mono))
            frame += count
        }
        out.append(contentsOf: resampler.finish())
        return out
    }
}
