import SwiftUI

/// Settings tab — the one functional shell tab in M0 (UX §10 device demo checks
/// the About version rows). Sections land per milestone:
/// Parts (M1 calibration), Grading (M4, J-405), Audio/latency (M1/M4),
/// Storage (M2 bundle management), Developer (J-002 inspector switch), About.
struct SettingsView: View {
    var body: some View {
        Form {
            section(
                "Parts",
                rows: [
                    Row(title: "Vocal ranges & calibration", detail: "Per-part range presets and mic calibration.", milestone: "M1"),
                ]
            )
            section(
                "Grading",
                rows: [
                    Row(title: "Tolerance & scoring display", detail: "±50/±25/±10 cents, octave equivalence, onset grace.", milestone: "M4"),
                    Row(title: "Guide level & count-in", detail: "Reference volume, metronome, haptics.", milestone: "M4"),
                ]
            )
            section(
                "Audio",
                rows: [
                    // J-102 ships the latency stub in the tuner; the real
                    // loopback procedure is M4 (UX §5.8).
                    Row(title: "Latency calibration", detail: "Loopback test and manual offset — stub lives in the tuner today.", milestone: "M4"),
                    Row(title: "Headphone policy", detail: "Guided to headphones for feedback; banners handle routing (J-102).", milestone: "M2"),
                ]
            )
            Section("Storage") {
                NavigationLink {
                    StorageScreen()
                } label: {
                    VStack(alignment: .leading, spacing: Token.Spacing.s1) {
                        Text("Song bundles")
                            .font(Token.Fonts.body)
                        Text("Per-song and total storage, delete all, interrupted-import cleanup.")
                            .font(Token.Fonts.caption)
                            .foregroundStyle(Color.pnTextSecondary)
                    }
                    .padding(.vertical, Token.Spacing.s1)
                }
                .accessibilityHint("Bundle storage management (J-204)")
            }
            Section("Models") {
                NavigationLink {
                    ModelsScreen()
                } label: {
                    VStack(alignment: .leading, spacing: Token.Spacing.s1) {
                        Text("Model manifest")
                            .font(Token.Fonts.body)
                        Text("Sizes, status, offline promise — download once, never again.")
                            .font(Token.Fonts.caption)
                            .foregroundStyle(Color.pnTextSecondary)
                    }
                    .padding(.vertical, Token.Spacing.s1)
                }
                .accessibilityHint("On-device model status (J-204)")
            }
            Section("Developer") {
                NavigationLink {
                    DebugPitchView()
                } label: {
                    VStack(alignment: .leading, spacing: Token.Spacing.s1) {
                        Text("Live pitch debug")
                            .font(Token.Fonts.body)
                        Text("Raw frames, RTF meter, engine identity — read latency for BENCHMARKS.md.")
                            .font(Token.Fonts.caption)
                            .foregroundStyle(Color.pnTextSecondary)
                    }
                    .padding(.vertical, Token.Spacing.s1)
                }
                .accessibilityHint("Live pitch debug measurements (J-103)")
                HStack {
                    VStack(alignment: .leading, spacing: Token.Spacing.s1) {
                        Text("Bundle inspector")
                            .font(Token.Fonts.body)
                        Text("Validate SongBundle files against the contract schemas (Library tab → song).")
                            .font(Token.Fonts.caption)
                            .foregroundStyle(Color.pnTextSecondary)
                    }
                    Spacer()
                }
                .padding(.vertical, Token.Spacing.s1)
                .accessibilityElement(children: .combine)
            }
            aboutSection
        }
        .scrollContentBackground(.hidden)
        .background(Color.pnBackground)
    }

    // MARK: - Rows

    private struct Row {
        let title: String
        let detail: String
        let milestone: String
    }

    private func section(_ name: String, rows: [Row]) -> some View {
        Section(name) {
            ForEach(rows, id: \.title) { row in
                HStack {
                    VStack(alignment: .leading, spacing: Token.Spacing.s1) {
                        Text(row.title)
                            .font(Token.Fonts.body)
                        Text(row.detail)
                            .font(Token.Fonts.caption)
                            .foregroundStyle(Color.pnTextSecondary)
                    }
                    Spacer()
                    MilestoneChip(milestone: row.milestone)
                }
                .padding(.vertical, Token.Spacing.s1)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.title), \(row.detail)")
                .accessibilityHint("Planned for milestone \(row.milestone)")
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            NavigationLink {
                LicensesView()
            } label: {
                Text("Licenses")
                    .font(Token.Fonts.body)
            }
            .accessibilityHint("Every shipped dependency and its license, with honest provenance tiers (J-204)")
            HStack {
                Text("Version")
                Spacer()
                Text(Self.marketingVersion)
                    .font(Token.Fonts.numeric)
                    .foregroundStyle(Color.pnTextSecondary)
            }
            .accessibilityElement(children: .combine)
            HStack {
                Text("Build")
                Spacer()
                Text(Self.buildNumber)
                    .font(Token.Fonts.numeric)
                    .foregroundStyle(Color.pnTextSecondary)
            }
            .accessibilityElement(children: .combine)
            Text("100% offline. Audio is processed on this device only and never leaves your iPhone.")
                .font(Token.Fonts.caption)
                .foregroundStyle(Color.pnTextSecondary)
        }
    }

    // MARK: - Version (UX §10 device demo step 8 expects 0.1.0 / 1)

    private static let marketingVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    private static let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
}
