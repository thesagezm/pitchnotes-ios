// BLAKE3 reference vectors generated with the OFFICIAL python binding
// (blake3 pypi pkg) 2026-11-22, data(i) = (i*181+7) % 251 per byte — same
// pattern family as upstream test_vectors.json (public domain). P-203.
import Foundation

struct Blake3Vector { let inputLength: Int; let hex: String }

enum Blake3Vectors {
    static let vectors: [Blake3Vector] = [
        .init(inputLength: 0, hex: "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"),
        .init(inputLength: 1, hex: "448bd8dd9624154a690f8e84dc52d6f633ba7cd545c4d3c9b4e0f6a2f6fa71f4"),
        .init(inputLength: 2, hex: "42d8db934a45e16fae4f83eb31584fc2fa73eb5f18a3ab82d74d8ef1d1c7d158"),
        .init(inputLength: 3, hex: "0ca1669c10c80835142bb7996e0b1051eca78bccca05c581d09b810b20863cb5"),
        .init(inputLength: 31, hex: "bfae29fb681eca49bce0739521f4ad335731b722ad5f2d3175cea2e26d41c94d"),
        .init(inputLength: 63, hex: "35d5ae565c94d3c369b29fe1a9ebe9d485deac146cdedb81503684d46589441e"),
        .init(inputLength: 64, hex: "244beded40975d8dd493d5eeeb96b53a39f534da870b90db03f9aebff2c5cf7b"),
        .init(inputLength: 65, hex: "02e97eaede04cb3cf962a7cf3d6ddc66bcddea2e0ce7932237f491b5a5652244"),
        .init(inputLength: 127, hex: "5e3924dff5caaa86fbb9fa8ee3d89576ebdf9bf8c6a2d4c4412f4cba10dddf74"),
        .init(inputLength: 128, hex: "c24e2f0cb377b4c2a613e73c9218b78deef3b22d90cf0d8fc886dccd5e8b4a86"),
        .init(inputLength: 129, hex: "3ba9cebad17dd2c6763b70f2d3c5de12cf97c157e3b1e8954898f3ed2191cf0d"),
        .init(inputLength: 255, hex: "d84e1bcd113fc3c4ce9c23a00d9cd1a8e26df7515a285fec4057ab87a979d7e4"),
        .init(inputLength: 256, hex: "1a2ab6e75679a73a49c26bc83f2196f1c0a5d4424c113dc78ceeb9b49ed47653"),
        .init(inputLength: 511, hex: "fd2cb0506af31f37ecd0d012a4da5e022e1f977b27b7a70f48807a87808e1b7c"),
        .init(inputLength: 1023, hex: "3cd0235f2f4012c7c3d1ca858e53d36165735a7a81666c35d3677a927a7f928c"),
        .init(inputLength: 1024, hex: "29a49d8bcd84567008ce6ae7002dc85c26a70a9aa1db207e64053875fcc5e940"),
        .init(inputLength: 1025, hex: "5e4cd44eaaa1c826aa894df4d13a304dcec5ff8b2f9f4d22a0ca7e6133ea1890"),
        .init(inputLength: 2048, hex: "c38b3eb19ab9d90908a2fffa42e34ea79befc9917bde32792bfd9c6d2bc10926"),
        .init(inputLength: 3072, hex: "b3231ef0a5a0ddfe745bb8e6d35dc6cf382e2ae5b675f5c1ea6ca8666799beac"),
        .init(inputLength: 4096, hex: "bcfea92ace20abbc0dbcc18589c7c09b46a5c73ee8e517a471c057e7ee2dd648"),
        .init(inputLength: 4097, hex: "7916cbc2fcb90f80c8641a0bbfda5e0fcae94e0c4fc252c8bb759eeb29c8b92f"),
        .init(inputLength: 8192, hex: "05eedb09fabc6cf416b5de8e1a3ac23ba236b5970b0d5f9dd3f5a430f6afa862"),
        .init(inputLength: 10000, hex: "529ca8d96a84eb37292d53635014e3347794af3b01f95e9db35f6aaa92a6adeb"),
    ]
    static func data(_ n: Int) -> Data {
        Data((0..<n).map { UInt8(($0 * 181 + 7) % 251) })
    }
}
