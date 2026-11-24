import SwiftUI
import PitchLogic
import EngineCore

/// Debug bundle inspector (J-002 → X-006 → J-202/J-205). Renders song.json /
/// notes / pitch shapes, the honest EngineCore contract verdicts per file
/// (disk truth — LibraryCatalog reads the materialized bundle, not the
/// generating script), and the D-22 tuning-reference section with override.
/// The first stop for bundle bug reports (UX §5.2).
struct BundleInspectorView: View {
    let song: LibrarySong
    /// J-205: called when the user changes the tuning-reference override
    /// (nil = back to the recording default). LibraryView wires this to the
    /// store-backed model; nil default keeps other call sites compiling.
    var onTuningOverrideChange: ((TuningOverride?) -> Void)?

    var body: some View {
        List {
            mixerEntry
            noteTracksEntry
            manifestSection
            provenanceSection
            tuningSection
            validationSection
            partsSection
            originNotice
        }
        .scrollContentBackground(.hidden)
        .background(Color.pnBackground)
        .navigationTitle("Bundle Inspector")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Piano roll entry (J-301)

    /// The per-part piano roll. The REAL entry renders the bundle's own note
    /// tracks (the same `[Part: NoteTrack]` the mock renders — the mock→real
    /// swap is zero-UI-change). Until the engine writes note tracks (P-305),
    /// the real entry says so honestly instead of showing an empty screen,
    /// and the MOCK demo entry is offered separately and clearly labelled.
    @ViewBuilder
    private var noteTracksEntry: some View {
        Section {
            if song.hasNoteTracks {
                NavigationLink {
                    // J-302: the corrected-first screen — the roll plus the
                    // user's corrections and the per-song part calibration.
                    NoteTracksScreen(bundleID: song.id,
                                     songTitle: song.manifest.title,
                                     rawTracks: song.noteTracks,
                                     duration_s: song.manifest.duration_s,
                                     isMock: false)
                } label: {
                    Label("Piano roll", systemImage: "music.note.list")
                        .fontWeight(.semibold)
                }
                .accessibilityHint("Per-part note tracks with confidence shading and unison badges")
            } else {
                Label("No note tracks in this bundle yet — they arrive with the engine's note tracker.",
                      systemImage: "clock.badge.questionmark")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
            }

            NavigationLink {
                NoteTracksScreen(bundleID: nil,
                                 songTitle: "Demo",
                                 rawTracks: MockNoteTracks.demoTracks(),
                                 duration_s: MockNoteTracks.demoDuration_s,
                                 isMock: true)
            } label: {
                Label("Piano roll (demo mock tracks)", systemImage: "wand.and.stars")
            }
            .accessibilityHint("Synthetic notes that show how the piano roll works")

            // J-303: the UltraStar export. One `.txt` per part, shareable so
            // the file can be checked in an EXTERNAL UltraStar player. When
            // the bundle has no real tracks yet, the DEMO tracks are exported
            // instead — clearly labelled as synthetic, never as a chart of the
            // song.
            NavigationLink {
                UltraStarExportView(tracks: song.hasNoteTracks ? song.noteTracks : MockNoteTracks.demoTracks(),
                                    songTitle: song.manifest.title,
                                    isMock: !song.hasNoteTracks)
            } label: {
                Label("Export UltraStar (.txt)", systemImage: "square.and.arrow.up")
            }
            .accessibilityHint("Writes one UltraStar text file per voice part")
        } header: {
            Text("Note tracks (M3)")
        } footer: {
            Text("Assignments are heuristic until you correct them — confidence shading and unison badges show where the engine is unsure.")
        }
    }

    // MARK: - Mixer entry (J-203)

    @ViewBuilder
    private var mixerEntry: some View {
        if song.bundleDirectory != nil {
            Section {
                NavigationLink {
                    MixerView(song: song)
                } label: {
                    Label("Listen (mixer)", systemImage: "slider.horizontal.3")
                        .fontWeight(.semibold)
                }
                .accessibilityHint("Per-stem faders, focus mix, transport with region loop")
            }
        }
    }

    // MARK: - Tuning reference (J-205, D-22)

    /// Detected offset + user override. The reference offsets; the audio
    /// never does. Demo rows and v0-era manifests show the honest "unknown".
    @State private var manualCentsDraft: Double = 0
    @State private var manualModeActive = false

    private var detectedCents: Int? { song.tuningCents }
    private var currentOverride: TuningOverride? { song.record?.tuningOverride }

    private var tuningSection: some View {
        Section {
            if let detected = detectedCents {
                let display = TuningDisplay(resolvedCents: TuningPolicy.resolvedCents(
                    detected: detected, override: currentOverride))
                HStack {
                    Image(systemName: "tuningfork")
                        .foregroundStyle(display.showsChip ? Color.octaveWarn : Color.inTune)
                        .accessibilityHidden(true)
                    Text(display.showsChip
                         ? display.label
                         : "Recording in tune with A440 (within \(TuningDisplay.defaultChipThreshold)c)")
                        .font(Token.Fonts.caption)
                }
                .accessibilityElement(children: .combine)
            } else {
                // Honest about WHY there is no estimate: a v0-era manifest
                // that predates `tuning_cents`, OR a v1.x manifest whose
                // estimate is missing/out-of-range (V14) or whose parts
                // disagree with `hasInstrumental` (V15) — the Validation
                // section below shows those violations by name.
                field("Tuning estimate", "— (no usable estimate in this manifest)")
            }

            if song.record != nil {
                Picker("Reference", selection: overrideSelection) {
                    Text("Recording").tag(0)
                    Text("Force A440").tag(1)
                    Text("Manual").tag(2)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Tuning reference override")
                .accessibilityHint("Recording follows the estimated offset; Force A440 ignores it; Manual sets cents")

                if manualModeActive {
                    Stepper(value: $manualCentsDraft, in: -50...50, step: 1) {
                        Text("Offset \(Int(manualCentsDraft) >= 0 ? "+" : "−")\(abs(Int(manualCentsDraft)))c")
                            .font(Token.Fonts.caption)
                    }
                    .accessibilityLabel("Manual offset, \(Int(manualCentsDraft)) cents")
                    Button("Apply manual offset") {
                        onTuningOverrideChange?(TuningOverride(
                            mode: .manual, manualCents: Int(manualCentsDraft)))
                    }
                    .font(Token.Fonts.caption)
                    .fontWeight(.semibold)
                }
            }
        } header: {
            Text("Tuning reference (D-22)")
        } footer: {
            Text("The grading REFERENCE offsets by this amount — your audio is never retuned (stored audio stays byte-true).")
        }
    }

    /// Index of the active override mode; selecting Manual seeds the stepper
    /// with the stored manual value (or the detected offset as a hint) and
    /// shows the apply row; Recording/A440 immediately persist and dismiss it.
    private var overrideSelection: Binding<Int> {
        Binding(
            get: {
                switch currentOverride?.mode {
                case .forceA440: return 1
                case .manual: return 2
                case .recording, .none: return 0
                }
            },
            set: { tag in
                switch tag {
                case 0:
                    manualModeActive = false
                    onTuningOverrideChange?(nil)
                case 1:
                    manualModeActive = false
                    onTuningOverrideChange?(TuningOverride(mode: .forceA440))
                default:
                    manualCentsDraft = Double(currentOverride?.manualCents ?? detectedCents ?? 0)
                    manualModeActive = true
                }
            })
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
            // C-2.1: meanNoteConfidence is 0.0 when the bundle carries NO note
            // tracks (every M2 two-stem bundle — note tracks arrive with M3).
            // "0.00" there would read as "zero confidence", so the field says
            // "not yet" instead (D-12 honesty).
            field("Mean note confidence",
                  song.hasNoteTracks
                  ? String(format: "%.2f", song.manifest.confidenceSummary.meanNoteConfidence)
                  : "not yet — no note tracks in this bundle")
        }
    }

    // MARK: - Provenance + storage (J-202)

    @ViewBuilder
    private var provenanceSection: some View {
        if let record = song.record {
            Section {
                field("Source file", record.sourceFileName.isEmpty ? "—" : record.sourceFileName)
                field("Added", record.addedAt.formatted(date: .abbreviated, time: .shortened))
                field("On-disk size", ByteCountFormatter.string(
                    fromByteCount: song.bytesOnDisk, countStyle: .file))
            } header: {
                Text("Import")
            } footer: {
                Text("The imported file is never re-read or modified (D-22: stored audio stays byte-true); deleting this song frees only the generated bundle.")
            }
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
                // notesFile is OPTIONAL since contract v1.0 (C-2.1: M2
                // two-stem manifests omit it); the typed-local normalization
                // compiles against both the pre-v1.0 PartInfo (required) and
                // the v1.0 PartInfo (String?).
                let notesFile: String? = partInfo.notesFile
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
                    field("notes", notesFile ?? "— (optional, absent)")
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

    @ViewBuilder
    private var originNotice: some View {
        if song.record == nil {
            Section {
                Text("Demo row — generated by MockEngine (P-001), deterministic contract-valid bundles (one is deliberately tampered on disk to prove the inspector catches real violations). Not your import; nothing here is deletable.")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
            }
        } else {
            Section {
                Text("Imported bundle — validated above against the real EngineCore rules over the files on disk. Report bundle problems with this screen attached (UX §5.2).")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
            }
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
