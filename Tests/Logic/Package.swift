// swift-tools-version: 5.9
import PackageDescription

// Pure-Swift logic core: scoring math, cents conversion, note-track parsing,
// UltraStar import/export, unison detection (AGENTS §6 logic-tests job).
// Runs with `swift test` on CI without audio hardware or Xcode.
//
// X-003/X-006 topology: contract TYPES (Part, NoteTrack, PitchFrame, validators)
// have ONE definition — Paul's EngineCore (CONTRACTS C-1 "no lane-local copies").
// PitchLogic consumes them via a local path dependency and adds Jess-lane logic
// on top (PitchMath, UnisonDetector). EngineCore is Foundation-only, so this
// package still compiles and tests on Linux with no audio hardware.
//
// Path: Engine/ is at the repo ROOT — two levels up from Tests/Logic (X-006
// correction of the original ../Engine quote; ruled by Leto in LOG).
let package = Package(
    name: "PitchLogic",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PitchLogic", targets: ["PitchLogic"]),
    ],
    dependencies: [
        .package(path: "../../Engine"),
    ],
    targets: [
        .target(
            name: "PitchLogic",
            dependencies: [.product(name: "EngineCore", package: "EngineCore")],
            path: "Sources/PitchLogic"
        ),
        .testTarget(
            name: "PitchLogicTests",
            dependencies: [
                "PitchLogic",
                .product(name: "EngineCore", package: "EngineCore"),
            ],
            path: "Tests/PitchLogicTests"
        ),
    ]
)
