import SwiftUI
import PitchLogic

/// Debug bundle inspector (J-002). Renders song.json / notes / pitch shapes and
/// the honest PitchLogic contract verdicts per file. Ships in Settings →
/// Developer; the first stop for bundle bug reports (UX §5.2).
struct BundleInspectorView: View {
    let song: StubSong

    var body: some View {
        List {
            manifestSection
            validationSection
            partsSection
            stubNotice
        }
        .scrollContentBackground(.hidden)
        .background(Color.pnBackground)
        .navigationTitle("Bundle Inspector")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Manifest (C-2.1)

    private var manifestSection: some View {
        Section("song.json") {
            field("Title", song.manifest.title)
            field("ID (ULID)", song.manifest.id)
            field("contractVersion", song.manifest.contractVersion)
            field("engineVersion", song.manifest.engineVersion)
            field("Duration", String(format: "%.2f s", song.manifest.duration_s))
            field("Sample rate", "\(song.manifest.sampleRate) Hz")
            field("Instrumental", song.manifest.hasInstrumental ? "present" : "none (D-9 acapella)")
            field("sourceHash", "\(song.manifest.sourceHash.algo) · \(song.manifest.sourceHash.hex)…")
            field("Mean note confidence", String(format: "%.2f", song.manifest.confidenceSummary.meanNoteConfidence))
        }
    }

    // MARK: - Validation (V1–V13 via PitchLogic)

    private var validationSection: some View {
        Section {
            ForEach(song.reports) { report in
                DisclosureGroup {
                    if report.violations.isEmpty {
                        Label("All applicable V-rules pass", systemImage: "checkmark.circle.fill")
                            .font(Token.Fonts.caption)
                            .foregroundStyle(Color.inTune)
                    } else {
                        ForEach(report.violations, id: \.self) { violation in
                            VStack(alignment: .leading, spacing: Token.Spacing.s1) {
                                Text("[\(violation.rule)]")
                                    .font(Token.Fonts.caption)
                                    .fontWeight(.bold)
                                    .foregroundStyle(Color.octaveWarn)
                                Text(violation.message)
                                    .font(Token.Fonts.caption)
                                    .foregroundStyle(Color.pnTextPrimary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Rule \(violation.rule) violated: \(violation.message)")
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: report.isValid ? "checkmark.seal.fill" : "xmark.octagon.fill")
                            .foregroundStyle(report.isValid ? Color.inTune : Color.octaveWarn)
                            .accessibilityHidden(true)
                        Text(report.fileName)
                            .font(Token.Fonts.numeric)
                        Spacer()
                        Text(report.isValid ? "PASS" : "FAIL (\(report.violations.count))")
                            .font(Token.Fonts.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(report.isValid ? Color.inTune : Color.octaveWarn)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(report.fileName): \(report.isValid ? "passes" : "fails contract with \(report.violations.count) violations")")
                }
            }
        } header: {
            Text("Contract validation (CONTRACTS v0.0)")
        } footer: {
            Text("Validation runs on the JSON surface — the actual contract — independent of the engine's Swift types.")
        }
    }

    // MARK: - Parts (C-2 stems/notes/pitch placeholders)

    private var partsSection: some View {
        Section("Parts") {
            ForEach(song.manifest.parts, id: \.part) { part in
                let partEnum = StubPart(rawValue: part.part)
                VStack(alignment: .leading, spacing: Token.Spacing.s2) {
                    HStack {
                        Text(partEnum?.displayName ?? part.part)
                            .font(Token.Fonts.body)
                            .fontWeight(.semibold)
                        Spacer()
                        Text("channels \(part.channels)")
                            .font(Token.Fonts.caption)
                            .foregroundStyle(Color.pnTextSecondary)
                        Text(String(format: "%.0f%%", part.noteConfidence * 100))
                            .font(Token.Fonts.numeric)
                            .foregroundStyle(Color.pnTextSecondary)
                    }
                    field("stem", part.stemFile)
                    field("notes", part.notesFile)
                    field("pitch", part.pitchFile ?? "— (optional, absent)")
                    let unison = song.unisonPairs.filter { $0.contains(partEnum?.displayName ?? part.part) }
                    if !unison.isEmpty {
                        Label("Unison: \(unison.joined(separator: ", ")) — pitch can't isolate this passage", systemImage: "waveform.badge.exclamationmark")
                            .font(Token.Fonts.caption)
                            .foregroundStyle(Color.flat)
                            .accessibilityLabel("Unison with \(unison.joined(separator: ", "))")
                    }
                }
                .padding(.vertical, Token.Spacing.s1)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var stubNotice: some View {
        Section {
            Text("Generated by the flagged preview StubEngine (J-002). Swaps to Paul's MockEngine (P-001) with zero UI changes.")
                .font(Token.Fonts.caption)
                .foregroundStyle(Color.pnTextSecondary)
        }
    }

    private func field(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name)
                .font(Token.Fonts.caption)
                .foregroundStyle(Color.pnTextSecondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(Token.Fonts.numeric)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name): \(value)")
    }
}
