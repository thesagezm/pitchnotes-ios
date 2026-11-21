// swift-tools-version: 5.9
import PackageDescription

// PitchORT (P-101, PAUL lane): Apple-only ONNX Runtime seam for the SwiftF0
// pitch engine. Lives OUTSIDE the EngineCore package because the ORT mirror's
// ObjC bindings are Apple-only (iOS 15 / macOS 14) — a dependency on them
// would break `cd Engine && swift test` on Linux (portable core stays clean,
// AGENTS §0). Wired into the app target via project.yml (Leto X-008).
let package = Package(
    name: "PitchORT",
    platforms: [.iOS(.v15), .macOS(.v14)],
    products: [
        .library(name: "PitchORT", targets: ["PitchORT"]),
    ],
    dependencies: [
        // D-13 pin: mirror tag 1.24.2 (rev 7dbd851, re-hosted binaries D-18.2).
        .package(url: "https://github.com/thesagezm/onnxruntime-swift-package-manager", exact: "1.24.2"),
        // Portable core: SwiftF0Inference protocol + engine orchestration.
        // Path fix (Leto, X-008 gate wiring): this package lives at
        // Engine/PitchORT — the EngineCore package is its PARENT directory
        // (`..`, path identity "Engine" — SPM keys local path deps by path
        // basename, not declared name; see J-FIX-101 note in Jess's
        // Tests/Logic/Package.swift). "../Engine" resolved to Engine/Engine
        // (run 44951410853 red).
        .package(path: ".."),
    ],
    targets: [
        .target(
            name: "PitchORT",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "EngineCore", package: "Engine"),
            ]),
        .testTarget(
            name: "PitchORTTests",
            dependencies: ["PitchORT"]),
    ]
)
