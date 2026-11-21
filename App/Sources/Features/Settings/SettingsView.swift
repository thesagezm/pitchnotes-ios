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
                    Row(title: "Latency calibration", detail: "Loopback test and manual offset for live feedback.", milestone: "M1"),
                ]
            )
            section(
                "Storage",
                rows: [
                    Row(title: "Song bundles", detail: "Stem storage use and per-song deletion.", milestone: "M2"),
                ]
            )
            section(
                "Developer",
                rows: [
                    Row(title: "Bundle inspector", detail: "Validate SongBundle files against the contract schemas.", milestone: "M0"),
                ]
            )
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
