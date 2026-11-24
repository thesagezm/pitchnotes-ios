import XCTest
@testable import PitchLogic

// SHA256 tests (J-207) — the portable hasher that verifies the model bytes.
//
// The vectors are the FIPS 180-4 / RFC 6234 known answers: if these pass,
// the digest is the real SHA-256 and the downloader's trust anchor means
// something. (CryptoKit cannot be used here: the logic-tests job also runs on
// Linux, where CryptoKit does not exist.)

final class SHA256Tests: XCTestCase {

    private func hex(_ string: String) -> Data { Data(string.utf8) }

    func testEmptyInputVector() {
        XCTAssertEqual(
            SHA256.hexDigest(of: Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testAbcVector() {
        XCTAssertEqual(
            SHA256.hexDigest(of: hex("abc")),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testQuickBrownFoxVector() {
        XCTAssertEqual(
            SHA256.hexDigest(of: hex("The quick brown fox jumps over the lazy dog")),
            "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
    }

    func testTwoBlockVector() {
        // 56 bytes exactly — the padding edge case (one extra block).
        let input = String(repeating: "a", count: 56)
        XCTAssertEqual(
            SHA256.hexDigest(of: hex(input)),
            "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
    }

    func testStreamingEqualsOneShot() {
        let payload = Data((0..<10_000).map { UInt8($0 % 251) })
        let oneShot = SHA256.hexDigest(of: payload)
        var hasher = SHA256Hasher()
        var offset = 0
        for chunkSize in [1, 7, 512, 4096] {
            offset = 0
            hasher = SHA256Hasher()
            while offset < payload.count {
                let end = min(offset + chunkSize, payload.count)
                hasher.update(payload.subdata(in: offset..<end))
                offset = end
            }
            XCTAssertEqual(hasher.finalizedHex(), oneShot,
                           "chunked hashing must equal the one-shot digest")
        }
    }

    func testFileDigestMatchesBufferDigest() throws {
        let payload = Data((0..<50_000).map { UInt8($0 % 97) })
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sha256-test-\(UUID().uuidString).bin")
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try SHA256.hexDigest(ofFileAt: url), SHA256.hexDigest(of: payload))
    }

    // MARK: - The comparison rules (a missing trust anchor never passes)

    func testMatchesAcceptsTheSameDigest() {
        let digest = SHA256.hexDigest(of: hex("abc"))
        XCTAssertTrue(SHA256.matches(computed: digest, expected: digest))
        XCTAssertTrue(SHA256.matches(computed: digest, expected: digest.uppercased()),
                      "hex comparison is case-insensitive")
        XCTAssertTrue(SHA256.matches(computed: digest, expected: "  \(digest)  "),
                      "surrounding whitespace is trimmed")
    }

    func testMatchesRejectsADifferentDigest() {
        let digest = SHA256.hexDigest(of: hex("abc"))
        let other = SHA256.hexDigest(of: hex("abd"))
        XCTAssertFalse(SHA256.matches(computed: digest, expected: other))
    }

    func testMatchesRejectsAMalformedExpectation() {
        let digest = SHA256.hexDigest(of: hex("abc"))
        XCTAssertFalse(SHA256.matches(computed: digest, expected: ""),
                       "an empty trust anchor must never pass")
        XCTAssertFalse(SHA256.matches(computed: digest, expected: String(digest.dropLast())),
                       "a short digest must never pass")
        XCTAssertFalse(SHA256.matches(computed: digest, expected: String(repeating: "z", count: 64)),
                       "a non-hex trust anchor must never pass")
    }
}
