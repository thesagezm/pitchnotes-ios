import SwiftUI
import PitchLogic

/// Library tab (J-002 → X-006 → J-202). Real imported songs first — disk
/// truth via BundleStore.scan() (a bundle exists IFF song.json parses;
/// cancelled imports' *.tmp staging never surfaces) — then the MockEngine
/// demo catalog until the real engine lands (P-204). Rows carry duration,
/// part chips, a cappella/confidence badges; imported rows add on-disk size,
/// import date and swipe-to-delete. Storage totals in the header.
struct LibraryView: View {
    @StateObject private var model = LibraryModel()
    @StateObject private var importModel = ImportModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var songToDelete: LibrarySong?

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView("Loading library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.pnBackground)
            } else {
                songList
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    importModel.isImportPickerPresented = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Import song")
                .accessibilityHint("Pick an MP3, FLAC, WAV or M4A file to import")
            }
        }
        .fileImporter(
            isPresented: $importModel.isImportPickerPresented,
            allowedContentTypes: ImportModel.supportedTypes,
            allowsMultipleSelection: false
        ) { importModel.handlePickerResult($0) }
        .sheet(isPresented: Binding(
            get: { importModel.phase != .idle },
            set: { if !$0 { importModel.reset() } }
        )) {
            ImportFlowSheet(model: importModel)
        }
        .onChange(of: scenePhase) { importModel.scenePhaseChanged($0) }
        // Import completed → disk truth changed → reload (new bundle appears).
        .onChange(of: importModel.phase) { phase in
            if case .completed = phase {
                Task { await model.load() }
            }
        }
        .confirmationDialog(
            "Delete song?",
            isPresented: Binding(
                get: { songToDelete != nil },
                set: { if !$0 { songToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let song = songToDelete { model.delete(song) }
                songToDelete = nil
            }
            Button("Cancel", role: .cancel) { songToDelete = nil }
        } message: {
            Text("“\(songToDelete?.manifest.title ?? "")” and its stems are removed from this iPhone. The original file you imported is not touched.")
        }
    }

    private var songList: some View {
        List {
            if let error = model.loadErrorMessage {
                errorBanner(error)
            }
            storageHeader
            if model.songs.isEmpty {
                emptyState
            } else {
                Section("Songs") {
                    ForEach(model.songs) { song in
                        NavigationLink {
                            BundleInspectorView(song: song) { override in
                                model.setTuningOverride(song, override: override)
                            }
                        } label: {
                            SongRow(song: song)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if song.isImported {
                                Button(role: .destructive) {
                                    songToDelete = song
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .accessibilityLabel("Delete \(song.manifest.title)")
                            }
                        }
                        .accessibilityLabel(songRowLabel(song))
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.pnBackground)
    }

    // MARK: - Header, error, empty

    private var storageHeader: some View {
        Section {
            VStack(alignment: .leading, spacing: Token.Spacing.s1) {
                HStack {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(Color.pnTextSecondary)
                        .accessibilityHidden(true)
                    Text("\(model.storageSummary) on device")
                        .font(Token.Fonts.caption)
                        .fontWeight(.semibold)
                    Spacer()
                    if model.allBundlesValid && !model.songs.isEmpty {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(Color.inTune)
                            .accessibilityLabel("All bundles pass contract validation")
                    }
                }
                if model.songs.contains(where: { !$0.isImported }) {
                    Text("Demo rows below are generated by the deterministic MockEngine — not your imports, not deletable.")
                        .font(Token.Fonts.caption)
                        .foregroundStyle(Color.pnTextSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            .listRowBackground(Color.pnSurfaceElevated)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Token.Spacing.s1) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.octaveWarn)
                Button("Retry") {
                    Task { await model.load() }
                }
                .font(Token.Fonts.caption)
                .fontWeight(.semibold)
            }
            .accessibilityElement(children: .combine)
            .listRowBackground(Color.pnSurfaceElevated)
        }
    }

    private var emptyState: some View {
        Section {
            VStack(spacing: Token.Spacing.s2) {
                Image(systemName: "music.note.list")
                    .font(.largeTitle)
                    .foregroundStyle(Color.pnTextSecondary)
                    .accessibilityHidden(true)
                Text("No songs yet")
                    .font(Token.Fonts.body)
                    .fontWeight(.semibold)
                Text("Tap + to import an MP3 or FLAC. Everything is processed and stored on this iPhone — nothing leaves it.")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Token.Spacing.s3)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Rows

    private func songRowLabel(_ song: LibrarySong) -> String {
        let verdict = song.allReportsValid
            ? "passes contract validation"
            : "fails contract validation"
        var label = "\(song.manifest.title), "
        if !song.isImported && !song.scenarioCaption.isEmpty {
            label += "demo row \(song.scenarioCaption), "
        }
        label += song.manifest.hasInstrumental ? "with instrumental backing, " : "a cappella, "
        label += "\(String(format: "%.1f", song.manifest.duration_s)) seconds, "
        if song.isImported {
            label += "\(ByteCountFormatter.string(fromByteCount: song.bytesOnDisk, countStyle: .file)) on disk, "
        }
        return label + verdict
    }

    private struct SongRow: View {
        let song: LibrarySong

        var body: some View {
            VStack(alignment: .leading, spacing: Token.Spacing.s2) {
                HStack {
                    Text(song.manifest.title)
                        .font(Token.Fonts.body)
                        .fontWeight(.semibold)
                    Spacer()
                    validationBadge
                }
                captionLine
                partChips
            }
            .padding(.vertical, Token.Spacing.s1)
        }

        private var validationBadge: some View {
            let valid = song.allReportsValid
            return Image(systemName: valid ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(valid ? Color.inTune : Color.octaveWarn)
                .accessibilityLabel(valid ? "Contract valid" : "Contract violations")
        }

        @ViewBuilder
        private var captionLine: some View {
            if let record = song.record {
                // Real import: provenance = the imported file + when + size.
                Text("\(record.sourceFileName.isEmpty ? "imported" : record.sourceFileName) · \(record.addedAt, format: .dateTime.day().month().year()) · \(ByteCountFormatter.string(fromByteCount: song.bytesOnDisk, countStyle: .file))")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
            } else {
                Text("Demo: \(song.scenarioCaption) · \(song.manifest.duration_s, specifier: "%.1f")s")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
            }
        }

        private var partChips: some View {
            HStack(spacing: Token.Spacing.s1) {
                aCappellaChip
                confidenceChip
                ForEach(song.manifest.parts, id: \.part) { part in
                    Text(part.part.displayName) // C-1 Part (EngineCore) + PitchLogic display names
                        .font(Token.Fonts.caption)
                        .padding(.horizontal, Token.Spacing.s2)
                        .padding(.vertical, 2)
                        .background(Color.pnTrack, in: Capsule())
                }
                if !song.unisonPairs.isEmpty {
                    Text("unison ×\(song.unisonPairs.count)")
                        .font(Token.Fonts.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, Token.Spacing.s2)
                        .padding(.vertical, 2)
                        .background(Color.flat.opacity(0.18), in: Capsule())
                        .accessibilityLabel("\(song.unisonPairs.count) unison passages")
                }
            }
        }

        /// D-9: `hasInstrumental == false` → a cappella (no backing track to
        /// mute); `true` → there is an INSTRUMENTAL stem (honest chip).
        private var aCappellaChip: some View {
            let aCappella = !song.manifest.hasInstrumental
            return Text(aCappella ? "a cappella" : "backed")
                .font(Token.Fonts.caption)
                .fontWeight(.semibold)
                .padding(.horizontal, Token.Spacing.s2)
                .padding(.vertical, 2)
                .background((aCappella ? Color.inTune : Color.pnTrack).opacity(0.25), in: Capsule())
                .accessibilityLabel(aCappella ? "A cappella recording" : "Has instrumental backing track")
        }

        /// Mean note confidence from the manifest (C-2.1) — amber under 60%
        /// (bleed-honesty: low-confidence separation, D-12).
        private var confidenceChip: some View {
            let confidence = song.manifest.confidenceSummary.meanNoteConfidence
            let low = confidence < 0.6
            return Text(String(format: "conf %.0f%%", confidence * 100))
                .font(Token.Fonts.caption)
                .fontWeight(low ? .semibold : .regular)
                .padding(.horizontal, Token.Spacing.s2)
                .padding(.vertical, 2)
                .background((low ? Color.octaveWarn : Color.pnTrack).opacity(0.25), in: Capsule())
                .accessibilityLabel("Mean note confidence \(Int(confidence * 100)) percent\(low ? ", low" : "")")
        }
    }
}
