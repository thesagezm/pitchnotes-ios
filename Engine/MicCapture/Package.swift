// swift-tools-version: 5.9
import PackageDescription

// MicCapture (P-104, PAUL lane): Apple-only mic-capture wrapper. Lives
// OUTSIDE the EngineCore package because AVFoundation/AVAudioSession are
// Apple-only (Linux `cd Engine && swift test` must stay clean, AGENTS §0) —
// same split rationale as PitchORT. The PORTABLE capture core
// (CapturePipeline / MicRingBuffer / StreamingResampler) lives in EngineCore
// and is Linux-tested; this package only binds it to the device:
// AVAudioEngine input tap → AVAudioConverter (→16 kHz) → CapturePipeline.
// Wired into the app target via project.yml (Leto: X-011).
let package = Package(
    name: "MicCapture",
    // iOS floor .v16 (Leto, gate run 44987823995): EngineCore (the dependency)
    // declares .iOS(.v16) — consumer cannot declare a lower iOS floor than its
    // dependency; app target is iOS 16.0 (D-3). macOS stays .v14. Flagged for
    // Paul's ratification (same lane-exception class as d16fe86).
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [
        .library(name: "MicCapture", targets: ["MicCapture"]),
    ],
    dependencies: [
        // Portable core: MicChunk + CapturePipeline + CaptureSpec.
        // Path fix (Leto, X-011 gate wiring): this package lives at
        // Engine/MicCapture — the EngineCore package is its PARENT directory
        // (`..`, path identity "Engine"; "../Engine" resolved to Engine/Engine,
        // run 44951410853 red). Same rationale as the PitchORT fix.
        .package(path: ".."),
    ],
    targets: [
        .target(
            name: "MicCapture",
            dependencies: [
                .product(name: "EngineCore", package: "Engine"),
            ]),
        .testTarget(
            name: "MicCaptureTests",
            dependencies: ["MicCapture"]),
    ]
)
