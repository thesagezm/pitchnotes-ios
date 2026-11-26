import SwiftUI
import PitchLogic
import os

// J-204 Settings v1 screens: Storage (per-song + total + cleanup), Licenses
// (LicensesCatalog — every shipped dep, honest tiers), Models (honest
// status list). Store I/O off main; D-12 honesty in every status row.

// MARK: - Storage (M2 bundle management)

@MainActor
final class StorageModel: ObservableObject {
    @Published private(set) var rows: [StorageRow] = []
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var strayStagingCount: Int = 0
    @Published private(set) var isLoading = true
    @Published var statusMessage: String?

    struct StorageRow: Identifiable {
        let id: String
        let title: String
        let bytes: Int64
        let isImported: Bool
    }

    private var store: BundleStore?

    func load() {
        isLoading = rows.isEmpty
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (BundleStore?, [StorageRow], Int64, Int) in
                guard let store = try? BundleStore.makeDefault() else { return (nil, [], 0, 0) }
                let records = store.scan()
                let songRows = records.map {
                    StorageRow(id: $0.id, title: $0.title,
                               bytes: store.bytesOnDisk(forID: $0.id), isImported: true)
                }
                return (store, songRows, store.totalBytesOnDisk(), store.strayStagingDirectoryCount())
            }.value
            store = result.0
            rows = result.1
            totalBytes = result.2
            strayStagingCount = result.3
            isLoading = false
        }
    }

    /// Deletes every imported bundle (demo catalog is untouched — tmp only).
    func deleteAll() {
        guard let store else { return }
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    for record in store.scan() {
                        try store.delete(id: record.id)
                    }
                    return nil
                } catch {
                    return "Delete-all stopped at an error: \(error)"
                }
            }.value
            statusMessage = outcome ?? "All imported songs deleted."
            load()
        }
    }

    func clearStrayStaging() {
        guard let store else { return }
        Task {
            let removed = await Task.detached(priority: .userInitiated) {
                store.clearStrayStagingDirectories()
            }.value
            statusMessage = removed == 0
                ? "No interrupted imports to clean up."
                : "Removed \(removed) interrupted import\(removed == 1 ? "" : "s")."
            load()
        }
    }
}

struct StorageScreen: View {
    @StateObject private var model = StorageModel()
    @State private var confirmDeleteAll = false

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "internaldrive").accessibilityHidden(true)
                    Text("\(ByteCountFormatter.string(fromByteCount: model.totalBytes, countStyle: .file)) used by PitchNotes")
                        .fontWeight(.semibold)
                }
                .accessibilityElement(children: .combine)

                Button {
                    model.clearStrayStaging()
                } label: {
                    Label("Clean up interrupted imports", systemImage: "arrow.triangle.2.circlepath.trash")
                }
                .disabled(model.strayStagingCount == 0)
                .accessibilityHint(model.strayStagingCount == 0
                    ? "Nothing to clean up"
                    : "\(model.strayStagingCount) interrupted import(s) on disk")

                Button(role: .destructive) {
                    confirmDeleteAll = true
                } label: {
                    Label("Delete all imported songs", systemImage: "trash")
                }
                .disabled(model.rows.isEmpty)
            } footer: {
                Text("Bundles are deletable cache — your original files in Files/ Music are never touched. Re-importing costs minutes, so nothing is evicted automatically (LRU policy copy: derived caches only).")
            }

            if let message = model.statusMessage {
                Section {
                    Text(message).font(Token.Fonts.caption)
                }
            }

            Section("Songs") {
                if model.rows.isEmpty {
                    Text("No imported songs yet.").font(Token.Fonts.caption)
                        .foregroundStyle(Color.pnTextSecondary)
                }
                ForEach(model.rows) { row in
                    HStack {
                        Text(row.title)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file))
                            .font(Token.Fonts.numeric)
                            .foregroundStyle(Color.pnTextSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(row.title), \(ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file))")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.pnBackground)
        .navigationTitle("Storage")
        .onAppear { model.load() }
        .confirmationDialog("Delete all imported songs?", isPresented: $confirmDeleteAll,
                            titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { model.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every imported song and its stems are removed from this iPhone. Original files are not touched.")
        }
    }
}

// MARK: - Licenses (J-204 AC: every shipped dep + its license)

struct LicensesView: View {
    var body: some View {
        List {
            Section {
                Text("Everything PitchNotes ships is permissively licensed; weights' provenance is stated honestly (Tier B is NOT certified clean; Tier C weights are study-only for commercial distribution — the basic-pitch ICASSP-2022 weights are trained on NC datasets and no sign-off can promote them, D-46). Study-only repos are never linked or copied.")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
            }
            shippedSection
            notShippedSection
        }
        .scrollContentBackground(.hidden)
        .background(Color.pnBackground)
        .navigationTitle("Licenses")
    }

    private var shippedSection: some View {
        Section("Shipped (or shipping at the M2 gate)") {
            ForEach(LicensesCatalog.shipped) { entry in
                licenseRow(entry)
            }
        }
    }

    private var notShippedSection: some View {
        Section("Not shipped for commercial distribution (study-only / pending sign-off / Tier C weights)") {
            ForEach(LicensesCatalog.entries.filter { !$0.ships }) { entry in
                licenseRow(entry)
            }
        }
    }

    private func licenseRow(_ entry: LicenseEntry) -> some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s1) {
            HStack {
                Text(entry.name).font(Token.Fonts.body).fontWeight(.semibold)
                Spacer()
                Text(entry.tier == .tierB ? "TIER B" : entry.tier.rawValue.uppercased())
                    .font(Token.Fonts.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(entry.tier == .tierB ? Color.octaveWarn : Color.pnTextSecondary)
            }
            Text(entry.role).font(Token.Fonts.caption)
            Text("\(entry.license) · ships: \(entry.shipsIn)")
                .font(Token.Fonts.caption)
                .foregroundStyle(Color.pnTextSecondary)
            if !entry.note.isEmpty {
                Text(entry.note)
                    .font(Token.Fonts.caption)
                    .foregroundStyle(entry.tier == .tierB ? Color.octaveWarn : Color.pnTextSecondary)
            }
        }
        .padding(.vertical, Token.Spacing.s1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.name), \(entry.license), ships \(entry.shipsIn)")
    }
}

// MARK: - Models (honest status list + one-time downloads, J-207)

/// The Models screen's state: the shipped-model list (honest descriptions)
/// plus the ONE-TIME DOWNLOADS the manifest drives (J-207, D-34 GAP 2).
///
/// D-12 honesty rules for this screen:
///   · a model that is not downloaded says so — no "ready" that means nothing;
///   · a download that cannot be verified NEVER turns into a cached file;
///   · when the manifest is not bundled in this build the screen says exactly
///     that (it never pretends a download is possible).
@MainActor
final class ModelsScreenModel: ObservableObject {

    struct DownloadRow: Identifiable {
        let id: String
        let name: String
        let sizeText: String
        let licenseText: String?
        var statusText: String
        var isCached: Bool
        var isBusy: Bool
        var progress: Double
    }

    @Published private(set) var downloadRows: [DownloadRow] = []
    @Published private(set) var manifestBundled = false
    @Published private(set) var manifestNote: String = ""
    @Published var statusMessage: String?

    private let service = ModelDownloadService()
    private var entries: [ModelManifestEntry] = []

    func load() {
        let entries = ModelCache.manifestEntries()
        self.entries = entries
        manifestBundled = !entries.isEmpty
        let location = ModelCache.bundledManifestLocation()
        manifestNote = entries.isEmpty
            ? "This build has no bundled model manifest, so downloads are unavailable. Place the model file in the app's Files folder instead — its checksum is still verified."
            : (location.map { "Manifest: \($0). " } ?? "")
                + "Downloaded once, verified against the manifest checksum, then cached. After this, airplane mode works end to end."
        downloadRows = entries.map { entry in
            let cached = FileManager.default.fileExists(atPath: ModelCache.cachedURL(for: entry).path)
            return DownloadRow(
                id: entry.name,
                name: entry.name,
                sizeText: ModelCacheNaming.sizeDescription(bytes: entry.sizeBytes),
                licenseText: entry.license,
                statusText: cached ? "Downloaded and verified — cached on this device." : "Not downloaded yet.",
                isCached: cached,
                isBusy: false,
                progress: 0)
        }
    }

    /// Download one model (one-time; the app needs a connection only here).
    func download(_ name: String) {
        guard let entry = entries.first(where: { $0.name == name }) else { return }
        setBusy(name, busy: true, progress: 0)
        statusMessage = nil
        Task {
            let outcome = await service.download(entry: entry) { [weak self] fraction in
                self?.setProgress(name, fraction)
            }
            finish(name: name, outcome: outcome)
        }
    }

    /// The gate's fallback: the human placed the file in the app's Files
    /// container — adopt it, but ONLY after the checksum matches.
    func adoptFromFiles(_ name: String) {
        guard let entry = entries.first(where: { $0.name == name }) else { return }
        setBusy(name, busy: true, progress: 0)
        statusMessage = nil
        Task {
            let outcome = await service.adoptFromDocuments(entry: entry)
            finish(name: name, outcome: outcome)
        }
    }

    private func setBusy(_ name: String, busy: Bool, progress: Double) {
        guard let index = downloadRows.firstIndex(where: { $0.id == name }) else { return }
        downloadRows[index].isBusy = busy
        downloadRows[index].progress = progress
    }

    private func setProgress(_ name: String, _ fraction: Double) {
        guard let index = downloadRows.firstIndex(where: { $0.id == name }) else { return }
        downloadRows[index].progress = fraction
        downloadRows[index].statusText = "Downloading… \(Int(fraction * 100))%"
    }

    private func finish(name: String, outcome: ModelDownloadService.Outcome) {
        setBusy(name, busy: false, progress: 0)
        guard let index = downloadRows.firstIndex(where: { $0.id == name }) else { return }
        switch outcome {
        case .alreadyCached:
            downloadRows[index].isCached = true
            downloadRows[index].statusText = "Downloaded and verified — cached on this device."
            statusMessage = "\(name) is already on this device."
        case .downloaded:
            downloadRows[index].isCached = true
            downloadRows[index].statusText = "Downloaded and verified — cached on this device."
            statusMessage = "\(name) downloaded and verified. Airplane mode works from here on."
        case .verificationFailed(let expected, let actual):
            downloadRows[index].statusText = "Verification failed — the file did not match the manifest checksum and was NOT cached."
            statusMessage = "Checksum mismatch for \(name) (expected \(expected), got \(actual)). Nothing was cached — please try again."
        case .failed(let message):
            downloadRows[index].statusText = "Download failed."
            statusMessage = message
        }
    }
}

struct ModelsScreen: View {
    @StateObject private var downloads = ModelsScreenModel()

    private let models: [(name: String, size: String, status: String, note: String)] = [
        ("SwiftF0", "~60 KB", "Shipped (M1)", "Grading-grade pitch stream."),
        ("MPM/YIN ribbon (vendored C)", "code only", "Shipped (M1)", "Live tuner, zero lookahead."),
        ("Silero VAD", "~2 MB", "Shipped (M1)", "Live voice-activity gating."),
        ("htdemucs fp16 ggml", "84 MB (83,994,361 B)", "M2 — manifest live (P-201 REVIEW)",
         "Two-stem separation (D-32.6 Retrobear fallback path, SHA256 trust anchor 72b17c42…df0064, re-verified byte-identical on upload). Tier B: \(LicensesCatalog.tierBProvenanceLine)"),
        ("basic-pitch", "~2 MB", "M3", "Multi-f0 note transcription."),
        ("RMVPE (optional)", "~180 MB", "Optional download (labeled)", "User-selected heavy alternative."),
    ]

    var body: some View {
        List {
            Section {
                Text("Models download once from the project Hugging Face repo, are verified (SHA256), cached, and NEVER needed again — airplane mode works end to end (AGENTS hard constraint 1). Model files never enter git.")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
            }
            Section("Manifest") {
                ForEach(models, id: \.name) { model in
                    VStack(alignment: .leading, spacing: Token.Spacing.s1) {
                        HStack {
                            Text(model.name).font(Token.Fonts.body).fontWeight(.semibold)
                            Spacer()
                            Text(model.size).font(Token.Fonts.numeric)
                                .foregroundStyle(Color.pnTextSecondary)
                        }
                        Text(model.status).font(Token.Fonts.caption)
                        if !model.note.isEmpty {
                            Text(model.note).font(Token.Fonts.caption)
                                .foregroundStyle(Color.pnTextSecondary)
                        }
                    }
                    .padding(.vertical, Token.Spacing.s1)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(model.name), \(model.size), \(model.status)")
                }
            }
            Section("One-time downloads") {
                Text(downloads.manifestNote)
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
                ForEach(downloads.downloadRows) { row in
                    VStack(alignment: .leading, spacing: Token.Spacing.s1) {
                        HStack {
                            Text(row.name).font(Token.Fonts.body).fontWeight(.semibold)
                            Spacer()
                            Text(row.sizeText).font(Token.Fonts.numeric)
                                .foregroundStyle(Color.pnTextSecondary)
                        }
                        Text(row.statusText).font(Token.Fonts.caption)
                        if let license = row.licenseText {
                            Text(license).font(Token.Fonts.caption)
                                .foregroundStyle(Color.pnTextSecondary)
                        }
                        if row.isBusy {
                            ProgressView(value: row.progress)
                                .progressViewStyle(.linear)
                                .accessibilityLabel("Downloading \(row.name)")
                                .accessibilityValue("\(Int(row.progress * 100)) percent")
                        }
                        if !row.isCached {
                            HStack(spacing: Token.Spacing.s3) {
                                Button("Download") { downloads.download(row.id) }
                                    .buttonStyle(.bordered)
                                    .disabled(row.isBusy)
                                    .accessibilityHint("Downloads once from the project model repo, then verifies the checksum.")
                                Button("Use file from Files") { downloads.adoptFromFiles(row.id) }
                                    .buttonStyle(.borderless)
                                    .disabled(row.isBusy)
                                    .accessibilityHint("Uses a model file you placed in the app's Files folder. Its checksum is still verified.")
                            }
                        }
                    }
                    .padding(.vertical, Token.Spacing.s1)
                    .accessibilityElement(children: .contain)
                }
                if let message = downloads.statusMessage {
                    Text(message)
                        .font(Token.Fonts.caption)
                        .foregroundStyle(Color.pnTextSecondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.pnBackground)
        .navigationTitle("Models")
        .onAppear { downloads.load() }
    }
}
