import SwiftUI
import PitchLogic

/// Library tab (J-002). M0: preview catalog from the flagged StubEngine +
/// debug bundle inspector. M2: this becomes the real imported-song list
/// (J-202) — row structure and inspector carry over unchanged.
struct LibraryView: View {
    @StateObject private var model = LibraryModel()

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView("Preparing preview catalog…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.pnBackground)
            } else {
                songList
            }
        }
        .navigationTitle("Library")
    }

    private var songList: some View {
        List {
            Section {
                // M0 preview notice — temporary by design (P-001 swap pending).
                VStack(alignment: .leading, spacing: Token.Spacing.s1) {
                    Text("Preview catalog — flagged StubEngine, not the real engine")
                        .font(Token.Fonts.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.pnTextSecondary)
                    Text("Swaps to Paul's MockEngine (P-001) with zero UI changes.")
                        .font(Token.Fonts.caption)
                        .foregroundStyle(Color.pnTextSecondary)
                }
                .accessibilityElement(children: .combine)
                .listRowBackground(Color.pnSurfaceElevated)
            }

            Section("Songs") {
                ForEach(model.songs) { song in
                    NavigationLink {
                        BundleInspectorView(song: song)
                    } label: {
                        SongRow(song: song)
                    }
                    .accessibilityLabel(songRowLabel(song))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.pnBackground)
    }

    private func songRowLabel(_ song: StubSong) -> String {
        let verdict = song.reports.allSatisfy(\.isValid)
            ? "passes contract validation"
            : "fails contract validation"
        return "\(song.manifest.title), scenario \(song.scenario.rawValue), \(String(format: "%.1f", song.manifest.duration_s)) seconds, \(verdict)"
    }

    private struct SongRow: View {
        let song: StubSong

        var body: some View {
            VStack(alignment: .leading, spacing: Token.Spacing.s2) {
                HStack {
                    Text(song.manifest.title)
                        .font(Token.Fonts.body)
                        .fontWeight(.semibold)
                    Spacer()
                    validationBadge
                }
                Text("Scenario: \(song.scenario.rawValue) · \(song.manifest.duration_s, specifier: "%.1f")s")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
                partChips
            }
            .padding(.vertical, Token.Spacing.s1)
        }

        private var validationBadge: some View {
            let valid = song.reports.allSatisfy(\.isValid)
            return Image(systemName: valid ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(valid ? Color.inTune : Color.octaveWarn)
                .accessibilityLabel(valid ? "Contract valid" : "Contract violations")
        }

        private var partChips: some View {
            HStack(spacing: Token.Spacing.s1) {
                ForEach(song.manifest.parts, id: \.part) { part in
                    Text(partName(part.part))
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

        private func partName(_ raw: String) -> String {
            StubPart(rawValue: raw)?.displayName ?? raw
        }
    }
}
