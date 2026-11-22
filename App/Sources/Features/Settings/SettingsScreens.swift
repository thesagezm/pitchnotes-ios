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
                Text("Everything PitchNotes ships is permissively licensed; weights' provenance is stated honestly (Tier B is NOT certified clean). Study-only repos are never linked or copied.")
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
        Section("Not shipped (study-only / pending sign-off)") {
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

// MARK: - Models (honest status list)

struct ModelsScreen: View {
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
        }
        .scrollContentBackground(.hidden)
        .background(Color.pnBackground)
        .navigationTitle("Models")
    }
}
