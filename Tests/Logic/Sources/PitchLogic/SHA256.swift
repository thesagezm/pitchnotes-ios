import Foundation

// SHA256 (J-207) — a PORTABLE SHA-256, in pure Swift.
//
// WHY NOT CryptoKit: the model downloader must VERIFY the bytes of an 84 MB
// weights file on the device (AGENTS §0 rail + D-34 GAP 2), and the
// logic-tests job runs on Linux as well as macOS — CryptoKit is Apple-only,
// so `import CryptoKit` in the shared package would break the Linux test
// loop (and the Docker `swift:6.0` loop this lane uses). A pure-Swift
// implementation keeps the package dependency-free and testable everywhere.
//
// This is a straight transcription of FIPS 180-4 SHA-256. It is used ONLY to
// verify a downloaded file against the manifest's SHA256 trust anchor; the
// security property that matters is "the bytes we cached are the bytes the
// manifest names", which the known-answer tests pin.
//
// The file variant streams the input in chunks: an 84 MB model is never held
// in memory as one buffer.

/// Streaming SHA-256 hasher (FIPS 180-4).
public struct SHA256Hasher {

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    private var buffer: [UInt8] = []
    private var totalBytes: UInt64 = 0

    public init() {}

    /// Feed a chunk of bytes.
    public mutating func update(_ bytes: [UInt8]) {
        totalBytes &+= UInt64(bytes.count)
        buffer.append(contentsOf: bytes)
        var offset = 0
        while buffer.count - offset >= 64 {
            compress(buffer[offset..<(offset + 64)])
            offset += 64
        }
        if offset > 0 { buffer.removeFirst(offset) }
    }

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { raw in
            update(Array(raw.bindMemory(to: UInt8.self)))
        }
    }

    /// Finish and return the lowercase hex digest.
    public mutating func finalizedHex() -> String {
        var message = buffer
        let bitLength = totalBytes &* 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for i in (0..<8).reversed() {
            message.append(UInt8((bitLength >> (UInt64(i) * 8)) & 0xff))
        }
        var offset = 0
        while offset < message.count {
            compress(message[offset..<(offset + 64)])
            offset += 64
        }
        buffer.removeAll()
        return state.map { String(format: "%08x", $0) }.joined()
    }

    private mutating func compress(_ block: ArraySlice<UInt8>) {
        var w = [UInt32](repeating: 0, count: 64)
        // An ArraySlice keeps the ORIGINAL indices of its parent array, so the
        // block is addressed relative to `startIndex` (not from zero).
        let base = block.startIndex
        for i in 0..<16 {
            let j = base + i * 4
            w[i] = (UInt32(block[j]) << 24)
                | (UInt32(block[j + 1]) << 16)
                | (UInt32(block[j + 2]) << 8)
                | UInt32(block[j + 3])
        }
        for i in 16..<64 {
            let s0 = Self.rotr(w[i - 15], 7) ^ Self.rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = Self.rotr(w[i - 2], 17) ^ Self.rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        for i in 0..<64 {
            let s1 = Self.rotr(e, 6) ^ Self.rotr(e, 11) ^ Self.rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let temp1 = h &+ s1 &+ ch &+ Self.k[i] &+ w[i]
            let s0 = Self.rotr(a, 2) ^ Self.rotr(a, 13) ^ Self.rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ maj
            h = g; g = f; f = e
            e = d &+ temp1
            d = c; c = b; b = a
            a = temp1 &+ temp2
        }
        state[0] = state[0] &+ a; state[1] = state[1] &+ b
        state[2] = state[2] &+ c; state[3] = state[3] &+ d
        state[4] = state[4] &+ e; state[5] = state[5] &+ f
        state[6] = state[6] &+ g; state[7] = state[7] &+ h
    }

    private static func rotr(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}

/// SHA-256 helpers used by the model downloader (J-207).
public enum SHA256 {

    /// Hex digest of a buffer.
    public static func hexDigest(of data: Data) -> String {
        var hasher = SHA256Hasher()
        hasher.update(data)
        return hasher.finalizedHex()
    }

    /// Hex digest of a file, streamed in 1 MB chunks (an 84 MB model is never
    /// loaded into memory as a whole).
    public static func hexDigest(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256Hasher()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(chunk)
        }
        return hasher.finalizedHex()
    }

    /// Compare a computed digest against the manifest's expected value.
    /// Case-insensitive (manifests may use uppercase hex); whitespace is
    /// trimmed. A malformed expected value NEVER matches (a missing trust
    /// anchor must not become a silent pass).
    public static func matches(computed: String, expected: String) -> Bool {
        let wanted = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard wanted.count == 64 else { return false }
        guard wanted.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return false }
        return computed.lowercased() == wanted
    }
}
