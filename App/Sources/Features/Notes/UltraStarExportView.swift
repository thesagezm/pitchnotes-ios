import SwiftUI
import UIKit
import PitchLogic
import EngineCore

// UltraStar export (J-303) — hands the note tracks to an EXTERNAL UltraStar
// player.
//
// WHY THIS EXISTS: J-303's acceptance includes "export playable in an external
// UltraStar player (manual check)". A logic module alone cannot be checked by
// a human — the files have to leave the app. So this writes one `.txt` per
// part (an UltraStar file is ONE melody; a NoteTrack is ONE part — C-2.3) and
// offers them to the system share sheet, so the human can drop them into
// Files/AirDrop and open them in a player.
//
// HONESTY (AGENTS §11 — a product requirement):
//   · the export says, in the UI, HOW MUCH the beat grid moved the timing
//     (the UltraStar format stores beats, not seconds — C-4);
//   · a MOCK track is exported under a name that says DEMO, and its #TITLE
//     says so too, so a synthetic file can never be mistaken for a
//     transcription of somebody's song;
//   · nothing here claims the assignment is right. The exported file is the
//     engine's current (possibly corrected) opinion.

/// The outcome of one export run.
struct UltraStarExportOutcome: Sendable {
    /// The files that were written.
    let urls: [URL]
    /// Everything the codec or the file writer had to say (quantization,
    /// clamped pitches, dropped material).
    let warnings: [String]
    /// The largest timing change the beat grid introduced, in seconds.
    let maxTimingError_s: Double
    /// The beat grid used.
    let bpm: Double
}

/// The export sheet: pick the tempo, export, share.
struct UltraStarExportView: View {
    /// The tracks to export (real bundle tracks, or the clearly-labelled mock).
    let tracks: [Part: NoteTrack]
    /// The song's title (used for the file names and `#TITLE`).
    let songTitle: String
    /// True when the tracks are the synthetic MOCK (the UI says so).
    let isMock: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var bpm: Double = UltraStarCodec.defaultBPM
    @State private var outcome: UltraStarExportOutcome?
    @State private var failure: String?
    @State private var isWorking = false
    @State private var isSharing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if isMock {
                        Label("These are SYNTHETIC demo notes, not a transcription. "
                              + "The exported files are named DEMO so they can never be mistaken for a real chart.",
                              systemImage: "wand.and.stars")
                            .font(Token.Fonts.caption)
                            .foregroundStyle(Color.octaveWarn)
                    }
                    VStack(alignment: .leading, spacing: Token.Spacing.s1) {
                        Text("Tempo (quarter note = 1 beat)")
                            .font(Token.Fonts.caption)
                            .foregroundStyle(Color.pnTextSecondary)
                        Slider(value: $bpm, in: 40...240, step: 1)
                        Text("\(Int(bpm)) BPM")
                            .font(Token.Fonts.numeric)
                    }
                    Text("The UltraStar format stores timing in BEATS (C-4), so the notes are placed on a "
                         + "beat grid. A higher BPM fits fast music with less rounding; a lower BPM fits slow "
                         + "music. The rounding is reported after the export.")
                        .font(Token.Fonts.caption)
                        .foregroundStyle(Color.pnTextSecondary)
                } header: {
                    Text("Export settings")
                }

                Section {
                    Button {
                        runExport()
                    } label: {
                        if isWorking {
                            ProgressView()
                        } else {
                            Label("Export \(tracks.count) file(s)", systemImage: "square.and.arrow.up")
                        }
                    }
                    .disabled(isWorking || tracks.isEmpty)
                }

                if let outcome {
                    Section {
                        Text("Timing moved by up to \(String(format: "%.3f", outcome.maxTimingError_s)) s "
                             + "by the \(Int(outcome.bpm)) BPM beat grid.")
                            .font(Token.Fonts.caption)
                            .foregroundStyle(Color.pnTextSecondary)
                        ForEach(outcome.urls, id: \.lastPathComponent) { url in
                            Text(url.lastPathComponent)
                                .font(Token.Fonts.numeric)
                        }
                        if !outcome.warnings.isEmpty {
                            ForEach(outcome.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(Token.Fonts.caption)
                                    .foregroundStyle(Color.octaveWarn)
                            }
                        }
                        Button {
                            isSharing = true
                        } label: {
                            Label("Share / save the files", systemImage: "square.and.arrow.up")
                        }
                    } header: {
                        Text("Exported")
                    } footer: {
                        Text("Open the files in an UltraStar-family player to check them. "
                             + "One file per part: a player shows one melody at a time.")
                    }
                }

                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(Token.Fonts.caption)
                            .foregroundStyle(Color.octaveWarn)
                    }
                }
            }
            .navigationTitle("UltraStar export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $isSharing) {
                if let outcome {
                    UltraStarShareSheet(items: outcome.urls)
                }
            }
        }
    }

    /// Write the files off the main thread (disk I/O), then report.
    private func runExport() {
        isWorking = true
        failure = nil
        let tracks = self.tracks
        let title = self.songTitle
        let mock = self.isMock
        let tempo = self.bpm

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try UltraStarFileWriter.write(tracks: tracks, songTitle: title,
                                                  isMock: mock, bpm: tempo)
                }.value
                await MainActor.run {
                    self.outcome = result
                    self.isWorking = false
                }
            } catch {
                await MainActor.run {
                    self.failure = error.localizedDescription
                    self.isWorking = false
                }
            }
        }
    }
}

/// Writes UltraStar files (one per part) into the app's Documents folder.
enum UltraStarFileWriter {

    /// The folder name inside Documents.
    static let folderName = "UltraStar Exports"

    /// Write one `.txt` per part.
    ///
    /// - Returns: the written files, the codec's warnings, and the largest
    ///   timing change the beat grid introduced.
    static func write(tracks: [Part: NoteTrack], songTitle: String, isMock: Bool,
                      bpm: Double) throws -> UltraStarExportOutcome {
        let fileManager = FileManager.default
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "UltraStarFileWriter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No documents folder is available."])
        }

        let baseName = sanitize(songTitle)
        let folderName = isMock ? "DEMO-\(baseName)" : baseName
        let folder = documents.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        var urls: [URL] = []
        var warnings: [String] = []
        var maxTimingError = 0.0

        for part in tracks.keys.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            guard let track = tracks[part] else { continue }
            let title = isMock
                ? "DEMO (synthetic notes) — \(songTitle)"
                : "\(songTitle) — \(part.displayName)"
            let result = try UltraStarCodec.export(track: track, bpm: bpm, title: title)

            let fileName = isMock ? "DEMO-\(part.rawValue).txt" : "\(part.rawValue).txt"
            let url = folder.appendingPathComponent(fileName)
            try result.text.write(to: url, atomically: true, encoding: .utf8)

            urls.append(url)
            warnings.append(contentsOf: result.warnings.map { "\(part.displayName): \($0)" })
            maxTimingError = max(maxTimingError, result.maxTimingError_s)
        }

        return UltraStarExportOutcome(urls: urls, warnings: warnings,
                                      maxTimingError_s: maxTimingError, bpm: bpm)
    }

    /// A file-name-safe form of the song title.
    static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        var cleaned = ""
        for character in name {
            let isAllowed = character.unicodeScalars.allSatisfy { allowed.contains($0) }
            cleaned.append(isAllowed ? String(character) : "-")
        }
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "PitchNotes" : String(trimmed.prefix(60))
    }
}

/// A small share sheet for the exported files (so they can reach Files,
/// AirDrop, or an UltraStar player).
struct UltraStarShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
