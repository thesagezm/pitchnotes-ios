import Foundation

// BLAKE3 — pure Swift, streaming, 32-byte digest (sourceHash per C-2.1: BLAKE3
// of the ORIGINAL imported file bytes, pre-decode).
//
// Implementation authored from the published BLAKE3 spec (github.com/
// BLAKE3-team/BLAKE3 — CC0 / Apache-2.0 dual-licensed; no upstream code copied).
// Correctness gate: Blake3Tests verifies all structural branches (0/1-byte,
// block, chunk, multi-chunk tree shapes) against vectors generated from the
// OFFICIAL Python binding — see Blake3Vectors.swift header.
//
// Throughput note: single-core scalar Swift ≈ hundreds of MB/s — far above what
// an import job needs (decode dominates); the hash is not a perf-critical path.

enum Blake3 {

    static let outLen = 32
    static let blockLen = 64
    static let chunkLen = 1024

    // SHA-256 IV (per spec).
    static let iv: [UInt32] = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
        0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
    ]

    // NOTE: the last two entries are (15, 8) — an earlier draft had (8, 15),
    // which only diverges on inputs whose message words 8/15 are nonzero
    // (caught by the official-vector test, length-64 case; n=0/1 pass either
    // way, which is exactly why the streaming-consistency test alone is not
    // enough of a gate).
    static let msgPermutation: [Int] = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]

    static let flagChunkStart: UInt32 = 1 << 0
    static let flagChunkEnd: UInt32 = 1 << 1
    static let flagParent: UInt32 = 1 << 2
    static let flagRoot: UInt32 = 1 << 3

    // MARK: - Compression core

    static func blockWords(_ block: [UInt8]) -> [UInt32] {
        precondition(block.count <= blockLen)
        var w = [UInt32](repeating: 0, count: 16)
        var o = 0
        for wi in 0..<16 {
            if o + 4 <= block.count {
                w[wi] = UInt32(block[o]) | UInt32(block[o + 1]) << 8
                    | UInt32(block[o + 2]) << 16 | UInt32(block[o + 3]) << 24
            } else if o < block.count {
                // Partial tail word: remaining bytes LOW-first, zero-padded
                // (reference impl: zero-filled block buffer, LE word reads).
                var v: UInt32 = 0
                var shift: UInt32 = 0
                while o < block.count {
                    v |= UInt32(block[o]) << shift
                    shift += 8
                    o += 1
                }
                w[wi] = v
                break
            } else {
                break
            }
            o += 4
        }
        return w
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }

    private static func g(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int,
                          _ mx: UInt32, _ my: UInt32) {
        s[a] &+= s[b] &+ mx
        s[d] ^= s[a]; s[d] = rotr(s[d], 16)
        s[c] &+= s[d]
        s[b] ^= s[c]; s[b] = rotr(s[b], 12)
        s[a] &+= s[b] &+ my
        s[d] ^= s[a]; s[d] = rotr(s[d], 8)
        s[c] &+= s[d]
        s[b] ^= s[c]; s[b] = rotr(s[b], 7)
    }

    /// 16-word compress output (words 0–7 = chaining / first half of the root,
    /// 8–15 = second half).
    static func compress(_ cv: [UInt32], _ blockWords: [UInt32],
                         counter: UInt64, blockLen: UInt32, flags: UInt32) -> [UInt32] {
        var s = [UInt32](repeating: 0, count: 16)
        for i in 0..<8 {
            s[i] = cv[i]
            s[i + 8] = iv[i]
        }
        s[12] = UInt32(truncatingIfNeeded: counter)
        s[13] = UInt32(truncatingIfNeeded: counter >> 32)
        s[14] = blockLen
        s[15] = flags

        var m = blockWords
        for r in 0..<7 {
            g(&s, 0, 4, 8, 12, m[0], m[1])
            g(&s, 1, 5, 9, 13, m[2], m[3])
            g(&s, 2, 6, 10, 14, m[4], m[5])
            g(&s, 3, 7, 11, 15, m[6], m[7])
            g(&s, 0, 5, 10, 15, m[8], m[9])
            g(&s, 1, 6, 11, 12, m[10], m[11])
            g(&s, 2, 7, 8, 13, m[12], m[13])
            g(&s, 3, 4, 9, 14, m[14], m[15])
            if r < 6 {
                var p = m
                for i in 0..<16 { m[i] = p[msgPermutation[i]] }
            }
        }
        for i in 0..<8 {
            s[i] ^= s[i + 8]
            s[i + 8] ^= cv[i]
        }
        return s
    }

    // MARK: - Output (compress inputs retained for chaining vs root reads)

    /// A pending compression: the ROOT flag is applied ONLY when reading root
    /// bytes — intermediate chaining values must compress without it (ROOT is
    /// an input to the compression function; adding it early changes words 0–7
    /// and would corrupt the tree fold).
    struct Output {
        let inputCV: [UInt32]
        let blockWords: [UInt32]
        let counter: UInt64
        let blockLen: UInt32
        let flags: UInt32

        func chainingValue() -> [UInt32] {
            Array(Blake3.compress(inputCV, blockWords, counter: counter,
                                  blockLen: blockLen, flags: flags)[0..<8])
        }

        func rootBytes(_ outLen: Int) -> [UInt8] {
            let out = Blake3.compress(inputCV, blockWords, counter: counter,
                                      blockLen: blockLen, flags: flags | Blake3.flagRoot)
            let words = min(outLen / 4, 16)
            return Blake3.wordsToBytes(Array(out[0..<words]))
        }
    }

    static func parentOutput(leftCV: [UInt32], rightCV: [UInt32], baseFlags: UInt32) -> Output {
        var block = leftCV
        block.append(contentsOf: rightCV)
        return Output(inputCV: iv, blockWords: block, counter: 0,
                      blockLen: UInt32(blockLen), flags: flagParent | baseFlags)
    }

    static func wordsToBytes(_ words: [UInt32]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(words.count * 4)
        for w in words {
            out.append(UInt8(truncatingIfNeeded: w))
            out.append(UInt8(truncatingIfNeeded: w >> 8))
            out.append(UInt8(truncatingIfNeeded: w >> 16))
            out.append(UInt8(truncatingIfNeeded: w >> 24))
        }
        return out
    }

    // MARK: - Chunk state

    /// Buffers ≤ 1 KiB of one chunk. Chaining is computed lazily from the
    /// retained buffer (≤ 16 block compressions per read; chunks emit once,
    /// finalize once — cost is trivial and keeps the state minimal).
    struct ChunkState {
        var chunkCounter: UInt64
        var buf: [UInt8] = []
        let baseFlags: UInt32 // hasher-level flags (0 for plain hash)

        init(chunkCounter: UInt64, baseFlags: UInt32) {
            self.chunkCounter = chunkCounter
            self.baseFlags = baseFlags
        }

        mutating func update(_ bytes: [UInt8]) {
            buf.append(contentsOf: bytes)
        }

        private func chainedThrough(_ fullBlocks: Int) -> [UInt32] {
            var cv = Blake3.iv
            var start = 0
            for bi in 0..<fullBlocks {
                var flags = baseFlags
                if bi == 0 { flags |= flagChunkStart }
                let w = Blake3.blockWords(Array(buf[start..<(start + Blake3.blockLen)]))
                cv = Blake3.chainingValueOf(cv, w, counter: chunkCounter,
                                            blockLen: UInt32(Blake3.blockLen), flags: flags)
                start += Blake3.blockLen
            }
            return cv
        }

        /// Output for the chunk's FINAL block (CHUNK_END; ROOT applied at read).
        /// Empty buffer = the zero-block with CHUNK_START|CHUNK_END (spec).
        func output() -> Output {
            let total = buf.count
            let fullBlocks = total / Blake3.blockLen
            let hasPartial = total % Blake3.blockLen > 0

            let chainTo = hasPartial ? fullBlocks : max(fullBlocks - 1, 0)
            let cv = chainedThrough(chainTo)

            let lastStart = hasPartial
                ? fullBlocks * Blake3.blockLen
                : max(fullBlocks - 1, 0) * Blake3.blockLen
            let lastLen: Int
            if total == 0 {
                lastLen = 0
            } else if hasPartial {
                lastLen = total - fullBlocks * Blake3.blockLen
            } else {
                lastLen = Blake3.blockLen
            }
            var flags = baseFlags
            if total <= Blake3.blockLen { flags |= flagChunkStart }
            flags |= flagChunkEnd
            let block = total == 0 ? [UInt8]() : Array(buf[lastStart..<total])
            return Output(inputCV: cv, blockWords: Blake3.blockWords(block),
                          counter: chunkCounter, blockLen: UInt32(lastLen), flags: flags)
        }
    }

    static func chainingValueOf(_ cv: [UInt32], _ w: [UInt32],
                                counter: UInt64, blockLen: UInt32, flags: UInt32) -> [UInt32] {
        Array(compress(cv, w, counter: counter, blockLen: blockLen, flags: flags)[0..<8])
    }

    // MARK: - Streaming hasher

    /// Streaming BLAKE3, 32-byte output. Plain hash only (keyed/derive-key
    /// modes are out of scope for sourceHash; the vectors cover plain mode).
    public struct Hasher {
        private var chunk = ChunkState(chunkCounter: 0, baseFlags: 0)
        private var cvStack: [[UInt32]] = []
        private var totalChunks: UInt64 = 0

        public init() {}

        public mutating func update(_ data: Data) {
            let bytes = [UInt8](data)
            var offset = 0
            while offset < bytes.count {
                let space = Blake3.chunkLen - chunk.buf.count
                let take = min(space, bytes.count - offset)
                chunk.update(Array(bytes[offset..<(offset + take)]))
                offset += take
                // Emit the completed chunk ONLY when more input follows — a
                // stream ending exactly on a chunk boundary must leave that
                // chunk as the final root chunk (reference impl: emission
                // happens at the top of the update loop, input permitting).
                // Eager emission here produced a phantom empty final chunk
                // and wrong tree shapes for exact multiples of 1024 (caught
                // by the official-vector test, length-1024 case).
                if chunk.buf.count == Blake3.chunkLen && offset < bytes.count {
                    emitChunk()
                }
            }
        }

        private mutating func emitChunk() {
            let cv = chunk.output().chainingValue()
            totalChunks += 1
            var count = totalChunks
            var merged = cv
            while count & 1 == 0 {
                let left = cvStack.removeLast()
                merged = Blake3.parentOutput(leftCV: left, rightCV: merged, baseFlags: 0)
                    .chainingValue()
                count >>= 1
            }
            cvStack.append(merged)
            chunk = ChunkState(chunkCounter: totalChunks, baseFlags: 0)
        }

        /// 32-byte digest.
        public func finalizeBytes() -> [UInt8] {
            var output = chunk.output()
            var stack = cvStack
            while let left = stack.popLast() {
                let rightCV = output.chainingValue()
                output = Blake3.parentOutput(leftCV: left, rightCV: rightCV, baseFlags: 0)
            }
            return output.rootBytes(Blake3.outLen)
        }

        public func finalizeHex() -> String {
            finalizeBytes().map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Whole-input convenience (32-byte digest).
    public static func hash(_ data: Data) -> Data {
        var h = Hasher()
        h.update(data)
        return Data(h.finalizeBytes())
    }
}

// MARK: - Source hashing seam (C-2.1: algo "blake3", hex of the ORIGINAL bytes)

/// Hashing seam: the import pipeline hashes the ORIGINAL imported file bytes
/// (pre-decode). Default = BLAKE3; tests may inject fakes via the protocol;
/// the manifest field stays `{algo, hex}`.
public protocol SourceHashing {
    /// Streams the file so multi-hundred-MB inputs never fully buffer.
    func hashFile(at url: URL) throws -> SourceHash
}

public struct Blake3FileHasher: SourceHashing {
    public init() {}

    public func hashFile(at url: URL) throws -> SourceHash {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var hasher = Blake3.Hasher()
        let chunkSize = 64 * 1024
        while true {
            let d = fh.readData(ofLength: chunkSize)
            if d.isEmpty { break }
            hasher.update(d)
            if d.count < chunkSize { break }
        }
        return SourceHash(algo: "blake3", hex: hasher.finalizeHex())
    }
}
