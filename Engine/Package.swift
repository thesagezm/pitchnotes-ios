// swift-tools-version: 5.9
import PackageDescription

// EngineCore — Paul's Foundation-only, portable engine core (AGENTS §0/§12).
// Implements CONTRACTS.md v0.0 exactly: C-1 Part enum, C-2 SongBundle schemas
// (song.json / NoteTrack / PitchFrames) + V1–V13 validators, C-3 EngineAPI
// protocol + PitchFrameStream, and the deterministic MockEngine (P-001).
//
// NO UIKit/SwiftUI/AVFoundation/ONNX imports here — this target compiles on
// Linux/Android (M6 port preflight, L-601). Apple-specific audio (AVFoundation
// I/O, ORT sessions) lives in separate engine targets wired by project.yml.
//
// Consumers:
//   - Jess (J-002/J-004): `.package(path: "../Engine")` in Tests/Logic/Package.swift,
//     `import EngineCore` — consume EngineAPI + MockEngine + validators.
//   - Leto (project.yml): same local package dependency pattern as PitchLogic.
let package = Package(
    name: "EngineCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "EngineCore", targets: ["EngineCore"]),
    ],
    targets: [
        .target(name: "EngineCore", path: "Sources/EngineCore"),
        .testTarget(
            name: "EngineCoreTests",
            dependencies: ["EngineCore"],
            path: "Tests/EngineCoreTests"
        ),
    ]
)
