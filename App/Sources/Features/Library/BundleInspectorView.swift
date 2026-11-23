import SwiftUI
import PitchLogic
import EngineCore

/// Debug bundle inspector (J-002 → X-006). Renders song.json / notes / pitch
/// shapes and the honest EngineCore contract verdicts per file (disk truth —
/// LibraryCatalog reads the materialized bundle, not the generating script).
/// Ships in Settings → Developer; the first stop for bundle bug reports (UX §5.2).
struct BundleInspectorView: View {
    let song: LibrarySong

    var body: some View {
        List {
            manifestSection
            validationSection
            partsSection
            mockNotice
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

    // MARK: - Validation (V1–V13 via EngineCore)

    private var validationSection: some View {
        Section {
            ForEach(song.reports) { report in
                DisclosureGroup {
                    if report.violations.isEmpty {
                        Label("All applicable V-rules pass", systemImage: "checkmark.circle.fill")
                            .font(Token.Fonts.caption)
                            .foregroundStyle(Color.inTune)
                    } else {
                        // ContractViolation is Equatable-only in EngineCore —
                        // iterate by index, not id: \.self.
                        ForEach(report.violations.indices, id: \.self) { index in
                            let violation = report.violations[index]
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
            Text("Validation via EngineCore V1–V13 over the materialized bundle on disk — disk truth, not the generating script.")
        }
    }

    // MARK: - Parts (C-2 stems/notes/pitch placeholders)

    private var partsSection: some View {
        Section("Parts") {
            ForEach(song.manifest.parts, id: \.part) { partInfo in
                let part = partInfo.part
                VStack(alignment: .leading, spacing: Token.Spacing.s2) {
                    HStack {
                        Text(part.displayName)
                            .font(Token.Fonts.body)
                            .fontWeight(.semibold)
                        Spacer()
                        Text("channels \(partInfo.channels)")
                            .font(Token.Fonts.caption)
                            .foregroundStyle(Color.pnTextSecondary)
                        Text(String(format: "%.0f%%", partInfo.noteConfidence * 100))
                            .font(Token.Fonts.numeric)
                            .foregroundStyle(Color.pnTextSecondary)
                    }
                    field("stem", partInfo.stemFile)
                    field("notes", partInfo.notesFile ?? "— (optional, absent)")
                    field("pitch", partInfo.pitchFile ?? "— (optional, absent)")
                    let unison = song.unisonPairs
                        .filter { $0.first == part || $0.second == part }
                        .map(UnisonDetector.label(for:))
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

    private var mockNotice: some View {
        Section {
            Text("Generated by MockEngine (P-001) — deterministic contract-valid bundles (one row deliberately tampered on disk to prove the inspector catches real violations). Real engine lands at M2 with zero UI changes.")
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
