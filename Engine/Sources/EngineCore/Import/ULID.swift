import Foundation

// ULID (C-2.1: song id = 26-char Crockford base32, uppercase) — 48-bit ms
// timestamp + 80-bit randomness. Authored per the ULID spec (adiulid/
// ulid spec — MIT-family reference; this is an independent minimal
// implementation, no code copied). Monotonicity across same-ms calls is not
// required for song ids (uniqueness probability ≫ sufficient).

public enum ULID {
    /// Crockford base32 alphabet (excludes I, L, O, U) — uppercase.
    public static let crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

    private static let encodingLen = 26
    private static let timeChars = 10

    public static func generate(now: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let ms = UInt64((now.timeIntervalSince1970 * 1000.0).rounded(.down))
        withUnsafeBytes(of: ms.bigEndian) { src in
            // 48-bit timestamp in the first 6 bytes (drop 2 high bytes).
            bytes[0] = src[src.count - 6]
            bytes[1] = src[src.count - 5]
            bytes[2] = src[src.count - 4]
            bytes[3] = src[src.count - 3]
            bytes[4] = src[src.count - 2]
            bytes[5] = src[src.count - 1]
        }
        var rng = SystemRandomNumberGenerator()
        for i in 6..<16 {
            bytes[i] = UInt8.random(in: 0...255, using: &rng)
        }
        return encode(bytes)
    }

    /// 128 bits → 26 Crockford base32 chars (standard ULID bit order: 130
    /// bits = 2 leading zero pad bits + 128 data, 5 bits per char MSB-first —
    /// the first char carries the top 3 bits of the timestamp, chars[0..10)
    /// are the time field, chars[10..26) the randomness).
    static func encode(_ bytes: [UInt8]) -> String {
        precondition(bytes.count == 16)
        var out = [Character](repeating: "0", count: encodingLen)
        var group = 0
        var offset = 0
        var val: UInt64 = 0
        func push(_ bit: UInt8) {
            val = (val << 1) | UInt64(bit)
            offset += 1
            if offset == 5 {
                out[group] = crockford[crockford.index(crockford.startIndex,
                                                       offsetBy: Int(val & 0x1F))]
                group += 1
                offset = 0
                val = 0
            }
        }
        push(0); push(0) // 130-bit frame: 2 leading zero pad bits
        for b in bytes {
            for shift in stride(from: 7, through: 0, by: -1) {
                push((b >> shift) & 1)
            }
        }
        return String(out)
    }
}
