// swift-tools-version: 5.9
import PackageDescription

// Pure-Swift logic core: scoring math, cents conversion, note-track parsing,
// UltraStar import/export, schema validation (AGENTS §6 logic-tests job).
// Runs with `swift test` on CI without audio hardware or Xcode.
let package = Package(
    name: "PitchLogic",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PitchLogic", targets: ["PitchLogic"]),
    ],
    targets: [
        .target(name: "PitchLogic", path: "Sources/PitchLogic"),
        .testTarget(
            name: "PitchLogicTests",
            dependencies: ["PitchLogic"],
            path: "Tests/PitchLogicTests"
        ),
    ]
)
