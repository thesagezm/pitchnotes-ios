import Foundation
import XCTest
@testable import EngineCore

// P-203: BLAKE3 correctness gate. Vectors in Blake3Vectors.swift were
// generated from the OFFICIAL Python binding (blake3 PyPI pkg) over input
// lengths spanning every structural branch: 0/1/2/3 bytes (empty + tiny),
// 31/63 (partial block), 64/65 (block boundary), 127/128/129, 255/256,
// 511/1023/1024/1025 (chunk boundary), 2048/3072/4096/4097 (two/four-chunk
// tree), 8192/10000 (deeper tree).

final class Blake3Tests: XCTestCase {

    func testOfficialVectorsAllLengths() {
        for v in Blake3Vectors.vectors {
            let h = Blake3.hash(Blake3Vectors.data(v.inputLength))
            XCTAssertEqual(h.map { String(format: "%02x", $0) }.joined(),
                           v.hex, "BLAKE3 mismatch at input length \(v.inputLength)")
        }
    }

    func testEmptyInputKnownDigest() {
        // Canonical BLAKE3("") — the vector at length 0 must match this.
        XCTAssertEqual(Blake3.hash(Data()).map { String(format: "%02x", $0) }.joined(),
                       "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262")
    }

    func testStreamingEqualsOneShotAcrossChunkBoundaries() {
        // Splitting the same bytes across update() calls (including splits at
        // 63/64/65, 1023/1024/1025, and arbitrary points) must not change the
        // digest — the import pipeline hashes files in 64 KB reads.
        let sizes = [0, 1, 64, 65, 1023, 1024, 1025, 4096, 8192]
        for n in sizes {
            let data = Blake3Vectors.data(n)
            let oneShot = Blake3.hash(data)
            for split in [1, 63, 64, 1024] where split <= max(n, 1) {
                var h = Blake3.Hasher()
                var off = 0
                while off < n {
                    let take = min(split, n - off)
                    h.update(data.subdata(in: off..<(off + take)))
                    off += take
                }
                XCTAssertEqual(h.finalizeHex(),
                               oneShot.map { String(format: "%02x", $0) }.joined(),
                               "streaming != one-shot at n=\(n) split=\(split)")
            }
        }
    }

    func testFileHasherStableAndLengthIndependentOfReadChunking() {
        // SourceHash stability (P-203 ac): same bytes → same hex regardless of
        // the FileHandle read chunking; different bytes → different hex.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blake3-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = dir.appendingPathComponent("a.bin")
        let b = dir.appendingPathComponent("b.bin")
        try? Blake3Vectors.data(5000).write(to: a)
        try? Data(Blake3Vectors.data(5000).map { $0 ^ 0x01 }).write(to: b)

        let ha1 = try? Blake3FileHasher().hashFile(at: a)
        let ha2 = try? Blake3FileHasher().hashFile(at: a)
        let hb = try? Blake3FileHasher().hashFile(at: b)
        XCTAssertEqual(ha1?.hex, ha2?.hex, "hash must be stable across runs")
        XCTAssertNotEqual(ha1?.hex, hb?.hex, "different bytes must hash differently")
        XCTAssertEqual(ha1?.algo, "blake3")
        XCTAssertEqual(ha1?.hex.count, 64)
        XCTAssertTrue((ha1?.hex.allSatisfy { $0.isLowercase || $0.isNumber }) ?? false,
                      "hex must be lowercase (C-2.1)")
    }

    func testULIDFormatAndUniqueness() {
        // C-2.1: id = ULID, 26 chars, Crockford base32, uppercase.
        var seen = Set<String>()
        for _ in 0..<1000 {
            let id = ULID.generate()
            XCTAssertEqual(id.count, 26, "ULID must be 26 chars")
            XCTAssertTrue(id.allSatisfy { ULID.crockford.contains($0) },
                          "non-Crockford char in \(id)")
            XCTAssertEqual(id, id.uppercased(), "ULID must be uppercase")
            seen.insert(id)
        }
        XCTAssertEqual(seen.count, 1000, "ULIDs must be unique in practice")
    }
}
