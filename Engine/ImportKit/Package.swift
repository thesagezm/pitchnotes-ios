// swift-tools-version: 5.9
import PackageDescription

// ImportKit (P-203, PAUL lane): Apple-only import decoder. Lives OUTSIDE the
// EngineCore package because AVFoundation is Apple-only (Linux `cd Engine &&
// swift test` must stay clean, AGENTS §0) — same split rationale as MicCapture
// and PitchORT. The PORTABLE import core (DecodePolicy / PCMF32Wav /
// AudioDecoding seam / ImportPipeline / BLAKE3) lives in EngineCore and is
// Linux-tested; this package only binds the seam to the device:
// AVAudioFile (native MP3/FLAC/ALAC/WAV decode) → interleaved source-rate
// samples → the SHARED EngineCore normalizeAndStage path (channel policy +
// deterministic sinc 44.1k). ONE normalization code path for all conformers.
//
// macOS tests prove the seam against the committed fixtures: FLAC/ALAC/WAV
// decode must be BIT-IDENTICAL to an ffmpeg reference decode (lossless
// containers); MP3 is tolerance-based (different decoders — honest note).
// Wired into the app target via project.yml (Leto: X-204).
let package = Package(
    name: "ImportKit",
    // Floors mirror the EngineCore dependency (iOS .v16 / macOS .v13; consumer
    // cannot declare lower than its dependency — MicCapture precedent).
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "ImportKit", targets: ["ImportKit"]),
    ],
    dependencies: [
        // Portable core: EngineCore package is this package's PARENT directory
        // (path identity "Engine"; "../Engine" would resolve Engine/Engine —
        // X-011 gate-wiring lesson).
        .package(path: ".."),
    ],
    targets: [
        .target(
            name: "ImportKit",
            dependencies: [
                .product(name: "EngineCore", package: "Engine"),
            ]),
        .testTarget(
            name: "ImportKitTests",
            dependencies: ["ImportKit"]),
    ]
)
