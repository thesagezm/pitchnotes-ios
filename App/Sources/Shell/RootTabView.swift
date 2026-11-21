import SwiftUI

/// Shell TabView (Docs/UX.md §2). Each tab owns a NavigationStack; content is
/// feature placeholders in M0 (J-001) and grows per milestone without
/// re-designing the shell.
struct RootTabView: View {
    @State private var selection: AppTab = .learn

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases) { tab in
                NavigationStack {
                    content(for: tab)
                        .navigationTitle(tab.title)
                        .navigationBarTitleDisplayMode(.large)
                }
                .tabItem {
                    Label(tab.title, systemImage: tab.icon)
                }
                .tag(tab)
                .accessibilityLabel(tab.title)
                .accessibilityHint(tab.a11yHint)
            }
        }
        .tint(.pnAccent)
    }

    @ViewBuilder
    private func content(for tab: AppTab) -> some View {
        switch tab {
        case .learn: LearnView()
        case .library: LibraryView()
        case .theory: TheoryView()
        case .ear: EarTrainingView()
        case .settings: SettingsView()
        }
    }
}

private extension AppTab {
    /// VoiceOver hint read after the tab title.
    var a11yHint: String {
        switch self {
        case .learn: return "Practice a part with live pitch feedback."
        case .library: return "Imported songs and their voice parts."
        case .theory: return "Music theory for your songs."
        case .ear: return "Ear training exercises."
        case .settings: return "App settings."
        }
    }
}

/// Reusable milestone placeholder (UX principle 6 — a roadmap, not a dead end).
/// M0 shells; each feature view swaps the body per milestone.
struct FeaturePlaceholder: View {
    let title: String
    let icon: String
    let milestone: String
    let blurb: String

    var body: some View {
        VStack(spacing: Token.Spacing.s4) {
            Image(systemName: icon)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Color.pnAccent)
                .accessibilityHidden(true)
            MilestoneChip(milestone: milestone)
            Text(blurb)
                .font(Token.Fonts.body)
                .foregroundStyle(Color.pnTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Token.Spacing.s5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.pnBackground)
        // One VoiceOver stop for the whole placeholder.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(blurb)")
        .accessibilityAddTraits(.isStaticText)
    }
}
