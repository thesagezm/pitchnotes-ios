import Foundation

// P-209 · Streaming separation seams (PAUL lane, portable core — Linux-tested).
//
// WHY THIS EXISTS: P-202's task line says "streaming decode→process→write", but
// the chunked driver still ACCUMULATED the blended stems for the whole song in
// memory (`ChunkedSeparationDriver.acc`) and the separation path slurped the
// staged mix whole. Both are O(song) terms: for a 4-minute stereo song ≈ 169 MB
// of accumulated stems + ≈ 169 MB of mix buffers. The L4(a) 4-minute run
// measured a 1805 MB peak and proved the VENDOR's per-segment working set
// (~1.7–1.8 GB) dominates the peak — but the Swift-side term was still there,
// and it is the term the task line asks to remove.
//
// THE SHAPE (additive — the accumulate path stays as the reference):
//   AudioWindowSource  → the staged mix, read WINDOW BY WINDOW from disk
//                         (file-backed, header parsed without loading the file)
//   StemStreamSink     → the staged stems, written AS THE BLEND COMPLETES
//                         (streaming 16-bit PCM WAV writer)
//   driver.runStreaming(…) blends into a PENDING buffer bounded by ONE window
//                         and writes the finalised frames out as it goes.
//
// The streamed output is asserted BIT-IDENTICAL to the accumulate path on the
// same fixture + mock SegmentEngine (the Linux test), so the CI-proven
// whole-song path is not destabilised by this refactor.
//
// The A14 DEVICE peak-RSS number is P-603's job: this is a code change, not a
// device measurement. What it removes is the O(song) TERM.

// MARK: - The mix source (window-by-window reads)

/// A read-only, randomly-addressable source of the staged mix.
///
/// The driver reads one window at a time — the source never has to hold the
/// whole song (that is the point of P-209). `channels` is the MIX layout
/// (D-8: 1 or 2); the vendor-facing processing layout is always stereo.
public protocol AudioWindowSource: Sendable {
    /// Total frames in the source.
    var totalFrames: Int { get }
    /// Channels in the mix layout (1 or 2 — D-8).
    var channels: Int { get }
    /// Reads `frameCount` frames starting at `startFrame` (channel-interleaved).
    func read(startFrame: Int, frameCount: Int) throws -> [Float]
}

public enum AudioWindowSourceError: Error, Sendable, Equatable {
    case range(startFrame: Int, frameCount: Int, totalFrames: Int)
    case notRIFF(String)
    case unsupportedFormat(String)
    case truncated(String)
    case ioFailure(String)
}

/// The in-memory source (tests + any caller that already holds the song).
public struct MemoryAudioWindowSource: AudioWindowSource {
    public let samples: [Float]
    public let channels: Int
    public var totalFrames: Int { samples.count / channels }

    public init(samples: [Float], channels: Int) {
        self.samples = samples
        self.channels = channels
    }

    public func read(startFrame: Int, frameCount: Int) throws -> [Float] {
        guard startFrame >= 0, frameCount >= 0,
              startFrame + frameCount <= totalFrames else {
            throw AudioWindowSourceError.range(startFrame: startFrame,
                                               frameCount: frameCount,
                                               totalFrames: totalFrames)
        }
        let from = startFrame * channels
        return Array(samples[from..<(from + frameCount * channels)])
    }
}

/// The FILE-BACKED source: a float32 staging WAV read window by window.
///
/// The header is parsed by scanning chunk headers with a file handle — the
/// file is never loaded into memory (the old path did `Data(contentsOf:)` on
/// the whole staged mix, which is an O(song) term).
public final class PCMF32WavWindowSource: AudioWindowSource, @unchecked Sendable {
    public let url: URL
    public let totalFrames: Int
    public let channels: Int
    public let sampleRate: Int

    private let dataOffset: UInt64
    private let bytesPerFrame: Int
    private let handle: FileHandle
    private let lock = NSLock()

    /// Opens `url` and parses its float32 WAV header.
    public init(url: URL) throws {
        self.url = url
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw AudioWindowSourceError.ioFailure("no such file: \(url.path)")
        }
        let h: FileHandle
        do {
            h = try FileHandle(forReadingFrom: url)
        } catch {
            throw AudioWindowSourceError.ioFailure("cannot open \(url.path): \(error.localizedDescription)")
        }
        self.handle = h

        let header = try Self.parseHeader(handle: h)
        self.dataOffset = header.dataOffset
        self.channels = header.channels
        self.sampleRate = header.sampleRate
        self.bytesPerFrame = header.channels * 4
        // `dataLength` is in BYTES; a frame is `channels` float32 samples.
        self.totalFrames = header.dataLength / (header.channels * 4)
    }

    deinit {
        try? handle.close()
    }

    public func read(startFrame: Int, frameCount: Int) throws -> [Float] {
        guard startFrame >= 0, frameCount >= 0,
              startFrame + frameCount <= totalFrames else {
            throw AudioWindowSourceError.range(startFrame: startFrame,
                                               frameCount: frameCount,
                                               totalFrames: totalFrames)
        }
        if frameCount == 0 { return [] }
        let byteCount = frameCount * bytesPerFrame
        lock.lock()
        defer { lock.unlock() }
        do {
            try handle.seek(toOffset: dataOffset + UInt64(startFrame * bytesPerFrame))
            guard let data = try handle.read(upToCount: byteCount), data.count == byteCount else {
                throw AudioWindowSourceError.truncated(
                    "staging mix ended before frame \(startFrame + frameCount)/\(totalFrames)")
            }
            var out = [Float](repeating: 0, count: frameCount * channels)
            let base = data.startIndex
            for i in 0..<out.count {
                let p = base + i * 4
                let bits = UInt32(data[p]) | UInt32(data[p + 1]) << 8
                    | UInt32(data[p + 2]) << 16 | UInt32(data[p + 3]) << 24
                out[i] = Float(bitPattern: bits)
            }
            return out
        } catch let error as AudioWindowSourceError {
            throw error
        } catch {
            throw AudioWindowSourceError.ioFailure(
                "read failed at frame \(startFrame): \(error.localizedDescription)")
        }
    }

    /// Scans the RIFF chunks with the handle (no whole-file read).
    private static func parseHeader(handle: FileHandle) throws
        -> (dataOffset: UInt64, dataLength: Int, channels: Int, sampleRate: Int) {
        func readAt(_ offset: UInt64, _ count: Int) throws -> [UInt8] {
            try handle.seek(toOffset: offset)
            guard let d = try handle.read(upToCount: count), d.count == count else {
                throw AudioWindowSourceError.truncated("header ended at offset \(offset)")
            }
            return [UInt8](d)
        }
        let riff = try readAt(0, 12)
        guard String(bytes: riff[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: riff[8..<12], encoding: .ascii) == "WAVE" else {
            throw AudioWindowSourceError.notRIFF("missing RIFF/WAVE header")
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
                guard fmt == 3 || (fmt == 0xFFFE && bits == 32) else {
                    throw AudioWindowSourceError.unsupportedFormat(
                        "staging source expects float32 WAV, got fmt \(fmt) bits \(bits)")
                }
                guard bits == 32 else {
                    throw AudioWindowSourceError.unsupportedFormat("bits/sample \(bits)")
                }
                guard channels == 1 || channels == 2 else {
                    throw AudioWindowSourceError.unsupportedFormat(
                        "staging source supports 1–2 channels, got \(channels)")
                }
                return (body, size, channels, sampleRate)
            default:
                break
            }
            offset = body + UInt64(size) + UInt64(size & 1)
        }
    }
}

/// Wraps a source and presents the PROCESSING layout (always stereo, per the
/// vendor/shim contract) — a mono mix is duplicated to L/R, exactly like the
/// old whole-song path (`SeparationChannels.upmixToStereo`).
public struct StereoWindowSource: AudioWindowSource, @unchecked Sendable {
    private let base: any AudioWindowSource
    public var totalFrames: Int { base.totalFrames }
    public var channels: Int { 2 }

    public init(base: any AudioWindowSource) {
        self.base = base
    }

    public func read(startFrame: Int, frameCount: Int) throws -> [Float] {
        let raw = try base.read(startFrame: startFrame, frameCount: frameCount)
        return try SeparationChannels.upmixToStereo(frames: raw, channels: base.channels)
    }
}

// MARK: - The stem sink (write-as-you-go)

/// Receives the blended stem output incrementally.
///
/// The sink belongs to ONE part (the driver asks the factory for one per part)
/// and is written in the PROCESSING layout (stereo, interleaved) — the D-8
/// stem channel policy (voice MONO / instrumental STEREO) is the sink's job,
/// applied as the frames are written (never mid-blend).
public protocol StemStreamSink: Sendable {
    /// Appends interleaved frames (frames × 2, the processing layout).
    func append(frames: [Float]) throws
    /// Finalises the sink (flush + patch the container header). Called ONLY
    /// after the last window — a sink that was never finished is partial.
    func finish() throws
    /// Aborts the sink: any partial output is discarded. Called on failure or
    /// cancellation (C-8: no residue, no partial stem file).
    func abort() throws
}

public extension StemStreamSink {
    func abort() throws {}
}

/// A streaming 16-bit PCM WAV writer (the stem staging format the ALAC
/// encoder reads — PCM16 is kept deliberately: the ALAC path is CI-proven with
/// 16-bit sources and the encoder's bit-depth hint follows the source).
///
/// Quantisation is IDENTICAL to `PCMWavWriter` (clamp to [-1, 1], scale by
/// 32767, round-to-nearest) so the staged stem bytes do not change when the
/// separation path moves to streaming.
///
/// The header is written with placeholder sizes and patched in `finish()` —
/// a file that was never finished is a partial file, and `abort()` removes it.
public final class PCM16StreamWriter: StemStreamSink, @unchecked Sendable {
    public let url: URL
    public let sampleRate: Int
    /// Channels written to the file (1 = mono fold, 2 = stereo).
    public let outputChannels: Int

    private let handle: FileHandle
    private let lock = NSLock()
    private var framesWritten = 0
    private var finished = false

    public init(url: URL, sampleRate: Int = DecodePolicy.targetSampleRate,
                outputChannels: Int) throws {
        guard outputChannels == 1 || outputChannels == 2 else {
            throw AudioWindowSourceError.unsupportedFormat(
                "stem writer supports 1–2 channels, got \(outputChannels)")
        }
        self.url = url
        self.sampleRate = sampleRate
        self.outputChannels = outputChannels
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw AudioWindowSourceError.ioFailure("cannot create \(url.path)")
        }
        let h: FileHandle
        do {
            h = try FileHandle(forWritingTo: url)
        } catch {
            throw AudioWindowSourceError.ioFailure("cannot open \(url.path) for writing: \(error.localizedDescription)")
        }
        self.handle = h
        // Placeholder header (44 bytes) — the sizes are patched in finish().
        var header = Data()
        func ascii(_ s: String) { header.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        let bytesPerSample = 2
        let byteRate = sampleRate * outputChannels * bytesPerSample
        ascii("RIFF"); u32(0); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(UInt16(outputChannels))
        u32(UInt32(sampleRate)); u32(UInt32(byteRate))
        u16(UInt16(outputChannels * bytesPerSample)); u16(16)
        ascii("data"); u32(0)
        try handle.write(contentsOf: header)
    }

    deinit {
        try? handle.close()
    }

    /// Appends interleaved frames from the PROCESSING layout (stereo). A mono
    /// output folds the channels with the channel MEAN — the same math as
    /// `SeparationChannels.toMono` (D-8's voice-stem policy).
    public func append(frames: [Float]) throws {
        guard !frames.isEmpty else { return }
        guard frames.count % 2 == 0 else {
            throw AudioWindowSourceError.unsupportedFormat(
                "stem frames are not frame-aligned in the stereo layout (\(frames.count) samples)")
        }
        lock.lock()
        defer { lock.unlock() }
        guard !finished else {
            throw AudioWindowSourceError.ioFailure("stem writer already finished")
        }
        let frameCount = frames.count / 2
        var pcm = Data()
        pcm.reserveCapacity(frameCount * outputChannels * 2)
        for f in 0..<frameCount {
            let l = frames[f * 2]
            let r = frames[f * 2 + 1]
            let value: Float = outputChannels == 1 ? 0.5 * (l + r) : l
            if outputChannels == 2 {
                appendQuantized(value, to: &pcm)
                appendQuantized(r, to: &pcm)
            } else {
                appendQuantized(value, to: &pcm)
            }
        }
        do {
            try handle.write(contentsOf: pcm)
        } catch {
            throw AudioWindowSourceError.ioFailure(
                "stem write failed at frame \(framesWritten): \(error.localizedDescription)")
        }
        framesWritten += frameCount
    }

    /// Same quantisation as `PCMWavWriter`: clamp, scale by 32767, round.
    private func appendQuantized(_ v: Float, to data: inout Data) {
        let clamped = max(-1.0, min(1.0, Double(v)))
        let s = Int16((clamped * 32767.0).rounded()).littleEndian
        withUnsafeBytes(of: s) { data.append(contentsOf: $0) }
    }

    /// Patches the RIFF/data sizes and closes the file. The file is COMPLETE
    /// only after this returns.
    public func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        let dataBytes = UInt32(framesWritten * outputChannels * 2)
        func u32Data(_ v: UInt32) -> Data {
            var d = Data()
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
            return d
        }
        do {
            // The RIFF chunk size lives at offset 4 and the data chunk size at
            // offset 40 — they are patched SEPARATELY (writing them as one
            // contiguous block would overwrite the "WAVE"/"fmt " identifiers).
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: u32Data(36 &+ dataBytes))
            try handle.seek(toOffset: 40)
            try handle.write(contentsOf: u32Data(dataBytes))
            try handle.synchronize()
            try handle.close()
        } catch {
            throw AudioWindowSourceError.ioFailure(
                "stem finalise failed for \(url.lastPathComponent): \(error.localizedDescription)")
        }
        finished = true
    }

    /// Closes and REMOVES the partial file (C-8: no residue).
    public func abort() throws {
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

/// A sink that collects the frames in memory (tests).
public final class MemoryStemSink: StemStreamSink, @unchecked Sendable {
    public let part: Part
    private let lock = NSLock()
    private var frames: [Float] = []
    private var finished = false
    private var aborted = false
    /// The largest chunk the sink was handed (the memory bound of one write).
    public private(set) var maxChunkFrames = 0

    public init(part: Part) {
        self.part = part
    }

    public func append(frames: [Float]) throws {
        lock.lock(); defer { lock.unlock() }
        self.frames.append(contentsOf: frames)
        maxChunkFrames = max(maxChunkFrames, frames.count / 2)
    }

    public func finish() throws {
        lock.lock(); defer { lock.unlock() }
        finished = true
    }

    public func abort() throws {
        lock.lock(); defer { lock.unlock() }
        aborted = true
        frames.removeAll()
    }

    public var collected: [Float] {
        lock.lock(); defer { lock.unlock() }; return frames
    }
    public var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }; return finished
    }
    public var isAborted: Bool {
        lock.lock(); defer { lock.unlock() }; return aborted
    }
}
