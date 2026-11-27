// swift-tools-version: 5.9
import PackageDescription

// PlaybackKit (P-402, PAUL lane): Apple-only reference-playback wrapper.
// Lives OUTSIDE the EngineCore package because AVAudioEngine /
// AVAudioUnitTimePitch are Apple-only (Linux `cd Engine && swift test` must
// stay clean, AGENTS §0) — the same split rationale as PitchORT /
// MicCapture / ImportKit. The PORTABLE mapping core (PlaybackTransform —
// CONTRACTS v1.2 C-20's key/tempo/latency mapping — and
// VarispeedPitchCompensation) lives in EngineCore and is Linux-tested; this
// package only binds it to the device: per-part AVAudioPlayerNode → per-lane
// AVAudioUnitTimePitch (pitch = transposition × 100 cents; rate = tempoScale,
// pitch-preserved) with a sample-accurate A/B loop and a host-time-anchored
// position clock. Wired into the app target via project.yml (LETO — the
// MicCapture/X-011 precedent; the wiring X-task carries the exact spec).
let package = Package(
    name: "PlaybackKit",
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [
        .library(name: "PlaybackKit", targets: ["PlaybackKit"]),
    ],
    dependencies: [
        // Portable core: PlaybackTransform + PlaybackEnvironment +
        // VarispeedPitchCompensation + the NoteTrack types. Path dep on the
        // PARENT (the MicCapture fix precedent: this package lives at
        // Engine/PlaybackKit, the EngineCore package is the parent directory).
        .package(path: ".."),
    ],
    targets: [
        .target(
            name: "PlaybackKit",
            dependencies: [
                .product(name: "EngineCore", package: "Engine"),
            ]),
        .testTarget(
            name: "PlaybackKitTests",
            dependencies: ["PlaybackKit"]),
    ]
)
