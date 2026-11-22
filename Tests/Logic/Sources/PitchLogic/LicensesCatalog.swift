import Foundation

// LicensesCatalog (J-204) — the single source of truth for the Settings →
// About → Licenses screen: EVERY dependency that ships (or is planned to
// ship) in the IPA, its license, and its provenance tier per AGENTS §9 /
// D-30 / D-21 / D-26 / X-310.
//
// Honesty rules baked into the data (enforced by LicensesManifestTests):
// · Tier B weights carry D-30's exact honest line ("trained on MUSDB18
//   (CC BY-NC-SA) + additional data — training-data risk recorded (D-30)") —
//   never presented as clean.
// · Anything dettato-derived carries the Apache-2.0 NOTICE attribution duty.
// · STUDY-ONLY repos (copyleft / AGPL app) are listed with ships == false —
//   we reimplement ideas, never link or copy code.
// · Tier C / NC-training-data candidates are listed as not-shipped pending
//   human sign-off (X-310 verdicts).

public enum LicenseTier: String, Codable, Sendable, CaseIterable {
    /// MIT/Apache/BSD — ship-safe per AGENTS §9.
    case shipSafe = "ship-safe"
    /// Ships with honest training-data risk copy (D-30) — e.g. htdemucs.
    case tierB = "tier-b"
    /// Not shipped pending human sign-off (X-310: BS-RoFormer-SW, MVSep).
    case tierC = "tier-c"
    /// STUDY-ONLY: copyleft/AGPL — never linked, never copied (AGENTS §9).
    case studyOnly = "study-only"
}

public struct LicenseEntry: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    /// What we use it for (one line).
    public let role: String
    public let license: String
    public let tier: LicenseTier
    /// Milestone the dep ships in ("M1", "M2", "M3", "never").
    public let shipsIn: String
    /// Provenance / attribution duty copy shown verbatim on the screen.
    public let note: String

    public var id: String { name }

    /// True when this entry's code/weights are linked into the shipped IPA.
    public var ships: Bool { tier == .shipSafe || tier == .tierB }

    public init(name: String, role: String, license: String, tier: LicenseTier,
                shipsIn: String, note: String) {
        self.name = name
        self.role = role
        self.license = license
        self.tier = tier
        self.shipsIn = shipsIn
        self.note = note
    }
}

public enum LicensesCatalog {

    /// D-30's exact honest line — Tier B entries MUST carry it (test-enforced).
    public static let tierBProvenanceLine =
        "trained on MUSDB18 (CC BY-NC-SA) + additional data — training-data risk recorded (D-30)"

    /// The dettato attribution duty (AGENTS §9, D-21/D-26).
    public static let dettatoNotice =
        "dettatto-derived: upstream Apache-2.0 NOTICE attribution carried in-app (D-21/D-26)"

    public static let entries: [LicenseEntry] = [
        LicenseEntry(
            name: "ONNX Runtime (mirror thesagezm/onnxruntime-swift-package-manager)",
            role: "CPU-first inference engine (all ONNX models)", license: "MIT",
            tier: .shipSafe, shipsIn: "M1", note: "Pinned tag 1.24.2 (D-13/D-29)."),
        LicenseEntry(
            name: "SwiftF0",
            role: "Grading-grade pitch stream (post-hoc, 176 ms lookahead)", license: "MIT",
            tier: .shipSafe, shipsIn: "M1", note: "ONNX weights ~60 KB."),
        LicenseEntry(
            name: "MPM/YIN causal ribbon (vendored pitch-detection)",
            role: "Live tuner ribbon source (zero lookahead)", license: "MIT",
            tier: .shipSafe, shipsIn: "M1", note: "C/C++ vendored; no training data."),
        LicenseEntry(
            name: "Silero VAD",
            role: "Voice-activity gating for live input (~2 MB)", license: "MIT",
            tier: .shipSafe, shipsIn: "M1", note: ""),
        LicenseEntry(
            name: "demucs.cpp",
            role: "Two-stem separation (VOCALS / INSTRUMENTAL)", license: "MIT",
            tier: .shipSafe, shipsIn: "M2", note: "Inference code only — weights' provenance below."),
        LicenseEntry(
            name: "Eigen",
            role: "Linear algebra headers vendored at demucs.cpp's submodule pin", license: "MPL-2.0",
            tier: .shipSafe, shipsIn: "M2",
            note: "Ship-safe for UNMODIFIED header-only use per D-32.5 — vendored unmodified; any local modification voids the MPL exception."),
        LicenseEntry(
            name: "htdemucs fp16 ggml weights",
            role: "Separation model (~81 MB)", license: "MIT (code) — weights Tier B",
            tier: .tierB, shipsIn: "M2",
            note: LicensesCatalog.tierBProvenanceLine
                + " User-facing copy stays honest: this is NOT certified clean-commercial."),
        LicenseEntry(
            name: "basicpitch.cpp + basic-pitch model",
            role: "Multi-f0 note transcription (M3)", license: "Apache-2.0",
            tier: .shipSafe, shipsIn: "M3", note: ""),
        LicenseEntry(
            name: "dettato-derived ports/weights",
            role: "Transcriber + grouping architecture (M3+)", license: "Apache-2.0",
            tier: .shipSafe, shipsIn: "M3",
            note: LicensesCatalog.dettatoNotice
                + " — dettato-grouper/drum WEIGHTS are banned from shipping (MUSDB18/IRMAS non-commercial training data, D-21.3)."),
        LicenseEntry(
            name: "signalsmith-stretch",
            role: "Tempo/pitch stretch for practice mode (future)", license: "MIT",
            tier: .shipSafe, shipsIn: "M5+", note: ""),
        LicenseEntry(
            name: "tonaljs",
            role: "Chord/scale labeling for theory exercises (M5)", license: "MIT",
            tier: .shipSafe, shipsIn: "M5", note: ""),
        LicenseEntry(
            name: "BS-RoFormer-SW + MVSep 53-stem checkpoints",
            role: "Optional heavy separation (user-selected)", license: "UNVERIFIED / Tier C",
            tier: .tierC, shipsIn: "never (pending human sign-off, X-310)",
            note: "X-310 verdict: Tier C — not shipped without human sign-off."),
        // STUDY-ONLY (AGENTS §9): listed so the screen can be honest about
        // what we deliberately do NOT ship.
        LicenseEntry(
            name: "Nightingale / Performous / USDX / Vocaluxe / UltraStar Play",
            role: "UltraStar-format reference implementations (ideas only)", license: "GPL-family",
            tier: .studyOnly, shipsIn: "never",
            note: "Copyleft — never linked or copied; semantics reimplemented (C-4)."),
        LicenseEntry(
            name: "aubio / essentia / TarsosDSP / PESTO / Verovio / FluidSynth / Rubber Band / GNU Solfege",
            role: "DSP/notation references (ideas only)", license: "GPL/LGPL/AGPL-family",
            tier: .studyOnly, shipsIn: "never",
            note: "Static linking makes LGPL dangerous for our IPA — never shipped."),
        LicenseEntry(
            name: "FuzzyIdeas/Muskey",
            role: "macOS pitch-study app (UX patterns reimplemented)", license: "AGPL-3.0",
            tier: .studyOnly, shipsIn: "never",
            note: "Statically links Essentia AGPL + Rubber Band GPL-2+ + PitchTap GPL-3; private macOS APIs. Never link/copy code, never hotlink its model CDN (D-26.1)."),
    ]

    /// Entries the Licenses screen shows first (what actually ships).
    public static var shipped: [LicenseEntry] {
        entries.filter(\.ships)
    }
}
