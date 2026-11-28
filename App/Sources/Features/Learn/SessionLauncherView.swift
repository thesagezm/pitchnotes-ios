import SwiftUI
import PitchLogic
import EngineCore

// SessionLauncherView (J-402) — the READY sheet (UX §5.4): the part chip, the
// tolerance picker (±50/±25/±10 — C-19's canonical stops), the octave
// toggle, the count-in picker, the latency badge (J-403's honest state), the
// [Start] action, and the honesty caption (focus mix, not solo; unison
// passages cannot be isolated — §3.7).
struct SessionLauncherView: View {

    /// The engine's (or the demo's) tracks — never mutated by the session.
    let rawTracks: [Part: NoteTrack]
    let bundleDirectory: URL?
    let songTitle: String
    let bundleId: String
    let isDemo: Bool
    let detectedTuningCents: Int
    let tuningOverride: TuningOverride?
    let onStart: (LearnSessionModel) -> Void

    @StateObject private var audio = AudioSessionController()
    /// The launcher's local selections — applied to the session at Start.
    @State private var selectedPart: Part?

    /// The singable parts the tracks actually carry (C-1 order).
    private var singableParts: [Part] {
        Part.allCases.filter { $0.isSingableVoice && rawTracks[$0] != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s3) {
            Text("Learn \(songTitle)")
                .font(Token.Fonts.heading)
            if isDemo {
                Label("DEMO — synthetic notes, not a real song.", systemImage: "flask")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.octaveWarn)
            }

            partChips
            tolerancePicker
            octaveToggle
            countInPicker
            latencyBadgeRow
            honestyCaption
            startButton
        }
        .padding(Token.Spacing.s4)
        .background(Color.pnSurface)
        .onAppear {
            audio.startObserving()
            applyStoredDefaults()
        }
        .onDisappear { audio.stopObserving() }
    }

    /// J-405: the sheet's controls START from the stored settings (the user
    /// can still pick differently for this one session).
    private func applyStoredDefaults() {
        let stored = GradingSettingsStore.load()
        toleranceSelection = Self.nearest(of: [50, 25, 10], to: stored.toleranceCents)
        octaveEquivalenceToggle = stored.octaveEquivalence
        countInSelection = Self.nearest(of: [0, 2, 4], to: stored.countIn_beats)
    }

    /// The picker's canonical stops (a stored value outside the stops maps
    /// to the nearest — the segmented picker has no free selection).
    private static func nearest(of stops: [Int], to value: Int) -> Int {
        stops.min { abs($0 - value) < abs($1 - value) } ?? stops.first ?? 0
    }

    private var partChips: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s1) {
            Text("Your part").font(Token.Fonts.caption)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Token.Spacing.s2) {
                    ForEach(singableParts, id: \.self) { part in
                        Button(part.displayName) {
                            selectedPart = part
                        }
                        .buttonStyle(.bordered)
                        .tint(selectedPart == part ? Color.pnAccent : Color.pnTextSecondary)
                        .accessibilityLabel("Sing \(part.displayName)")
                    }
                }
            }
        }
    }

    private var tolerancePicker: some View {
        Picker("Tolerance", selection: $toleranceSelection) {
            Text("±50").tag(50)
            Text("±25").tag(25)
            Text("±10").tag(10)
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Grading tolerance in cents")
    }

    @State private var toleranceSelection: Int = 50

    private var octaveToggle: some View {
        Toggle("Forgive octave errors", isOn: $octaveEquivalenceToggle)
            .font(Token.Fonts.caption)
    }

    @State private var octaveEquivalenceToggle: Bool = true

    private var countInPicker: some View {
        Picker("Count-in", selection: $countInSelection) {
            Text("Off").tag(0)
            Text("2 beats").tag(2)
            Text("4 beats").tag(4)
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Count-in beats")
    }

    @State private var countInSelection: Int = 4

    private var latencyBadgeRow: some View {
        // Hoisted out of the interpolation on purpose: a multi-line expression
        // inside a single-line string literal does not parse (red run 46090525518).
        let resolved = LatencyResolver.resolve(
            stored: LatencyCalibration.load(),
            currentRouteID: AudioSessionController.currentRouteID)
        return Text("Latency: \(resolved.badge.label)")
            .font(Token.Fonts.caption)
            .foregroundStyle(Color.pnTextSecondary)
    }

    private var honestyCaption: some View {
        Text("You'll sing over a focus mix — the other parts are softened, not removed, and unison passages can't be isolated. The grade reads the notes the engine detected; correct any wrong one and your fix wins.")
            .font(Token.Fonts.caption)
            .foregroundStyle(Color.pnTextSecondary)
    }

    private var startButton: some View {
        Button("Start") { beginSession() }
            .buttonStyle(.borderedProminent)
            .disabled(singableParts.isEmpty)
    }

    private func beginSession() {
        let session = LearnSessionModel(
            rawTracks: rawTracks,
            bundleDirectory: bundleDirectory,
            title: songTitle,
            bundleId: bundleId,
            isDemo: isDemo,
            detectedTuningCents: detectedTuningCents,
            tuningOverride: tuningOverride)
        session.selectedPart = selectedPart ?? session.selectedPart
        session.tolerancePreset = toleranceSelection
        session.octaveEquivalence = octaveEquivalenceToggle
        session.countIn_beats = countInSelection
        session.refreshLatency()
        onStart(session)
    }
}
