import SwiftUI
import EngineCore
import PitchLogic

// ImportView (J-201) — the import flow sheet (UX §5.1): setup → staged
// progress (C-8: decode → separate → assemble) → done, with cancel and every
// error state. Accessibility: every control labeled; the progress bar exposes
// value + stage via accessibilityValue; all text uses Token fonts (dynamic
// type). VoiceOver reads the stage row states.

struct ImportFlowSheet: View {
    @ObservedObject var model: ImportModel

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .idle:
                    EmptyView()
                case .setup(let info):
                    setupView(info)
                case .running, .cancelling:
                    progressView
                case .completed(let title):
                    doneView(title)
                case .failed(let error):
                    failureView(error)
                }
            }
            .background(Color.pnBackground)
            .navigationTitle("Import song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Hide the X while running — use [Cancel] (cooperative) instead.
                if !model.isImportInFlight {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { model.reset() }
                    }
                }
            }
            .interactiveDismissDisabled(model.isImportInFlight)
        }
    }

    // MARK: - Setup (UX §5.1: title prefilled, format, size)

    private func setupView(_ info: ImportModel.SetupInfo) -> some View {
        Form {
            Section {
                HStack(spacing: Token.Spacing.s3) {
                    Image(systemName: "waveform")
                        .font(.title2)
                        .foregroundStyle(Color.pnAccent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Token.Spacing.s1) {
                        Text(info.url.lastPathComponent)
                            .font(Token.Fonts.body)
                            .fontWeight(.semibold)
                            .lineLimit(2)
                        Text("\(info.formatLabel) · \(ByteCountFormatter.string(fromByteCount: info.sizeBytes, countStyle: .file))")
                            .font(Token.Fonts.caption)
                            .foregroundStyle(Color.pnTextSecondary)
                    }
                }
                TextField("Song title", text: $model.setupTitle)
                    .font(Token.Fonts.body)
                    .accessibilityLabel("Song title")
            } header: {
                Text("File")
            }

            Section {
                // D-9: two-stem separation ALWAYS runs; near-silent
                // instrumental is hidden later (hasInstrumental=false). The
                // M1 storyboard's "Remove instruments?" toggle is therefore
                // not a user choice in M2 — one honest line instead.
                Label("Instruments are removed automatically. If none are found, the song is marked a cappella.",
                      systemImage: "music.note.2")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
            } header: {
                Text("What happens")
            }

            if model.thermalAdvice.message != nil {
                Section {
                    thermalBanner
                }
            }

            Section("Recent imports") {
                if model.recentRecords.isEmpty {
                    Text("No songs imported yet.")
                        .font(Token.Fonts.caption)
                        .foregroundStyle(Color.pnTextSecondary)
                } else {
                    ForEach(model.recentRecords.prefix(5)) { record in
                        HStack {
                            Text(record.title)
                                .font(Token.Fonts.body)
                                .lineLimit(1)
                            Spacer()
                            Text(record.sourceFileName)
                                .font(Token.Fonts.caption)
                                .foregroundStyle(Color.pnTextSecondary)
                                .lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            Section {
                Button {
                    model.beginImport()
                } label: {
                    Text("Start import")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
                .accessibilityHint("Separation runs on this device; keep the app open until it finishes.")
            }
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var thermalBanner: some View {
        if let message = model.thermalAdvice.message {
            Label(message, systemImage: model.thermalAdvice.isDeferred ? "thermometer.high" : "thermometer.medium")
                .font(Token.Fonts.caption)
                .foregroundStyle(Color.octaveWarn)
                .accessibilityLabel("Thermal notice: \(message)")
        }
    }

    // MARK: - Progress (C-8 stages, monotonic overall bar)

    private var progressView: some View {
        VStack(spacing: Token.Spacing.s5) {
            Spacer()
            engineBadge
            stageList
            progressBar
            detailLine
            liveMetricsLine
            if model.importContinuesInBackground {
                Text("Import continues in the background. If iOS suspends the app, this import is discarded — nothing partial is saved.")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Token.Spacing.s4)
            }
            Spacer()
            cancelButton
        }
        .padding()
    }

    /// J-208: says out loud WHICH engine runs — a mock demo must never look
    /// like a real separation (D-12 honesty; the M2 gate requires the real
    /// path).
    private var engineBadge: some View {
        Text(model.engineKind.statusLine)
            .font(Token.Fonts.caption)
            .foregroundStyle(model.engineKind.isReal ? Color.pnTextSecondary : Color.octaveWarn)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Token.Spacing.s4)
            .accessibilityLabel("Engine: \(model.engineKind.statusLine)")
    }

    /// J-206: the live peak footprint while the import runs.
    private var liveMetricsLine: some View {
        Text("Peak memory so far: \(ImportMetricsFormatter.residentBytes(model.livePeakResidentBytes))")
            .font(Token.Fonts.caption)
            .foregroundStyle(Color.pnTextSecondary)
            .accessibilityLabel("Peak memory so far: \(ImportMetricsFormatter.residentBytes(model.livePeakResidentBytes))")
    }

    private var stageList: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s3) {
            ForEach(Array(ImportStage.allCases.enumerated()), id: \.element) { index, stage in
                stageRow(stage: stage, index: index)
            }
        }
        .padding(.horizontal, Token.Spacing.s4)
    }

    private func stageRow(stage: ImportStage, index: Int) -> some View {
        let currentIndex = ImportStage.allCases.firstIndex(of: model.progress?.stage ?? .decoding) ?? 0
        let state: StageRowState = index < currentIndex
            ? .done
            : (index == currentIndex ? (model.progress == nil ? .pending : .active) : .pending)

        return HStack(spacing: Token.Spacing.s3) {
            Image(systemName: state.icon)
                .foregroundStyle(state.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(stage.displayTitle).font(Token.Fonts.body)
                Text(state.caption(for: stage))
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
            }
            Spacer()
        }
        .opacity(state == .pending ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stage.displayTitle): \(state.spokenLabel)")
    }

    private var progressBar: some View {
        VStack(spacing: Token.Spacing.s2) {
            ProgressView(value: model.progress?.fraction ?? 0)
                .progressViewStyle(.linear)
                .tint(Color.pnAccent)
                .accessibilityLabel("Import progress")
                .accessibilityValue(progressSpokenValue)
            HStack {
                Text("\(Int((model.progress?.fraction ?? 0) * 100))%")
                    .font(Token.Fonts.numeric)
                Spacer()
                if let startedAt = elapsedStart {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(elapsedText(since: startedAt, at: context.date))
                            .font(Token.Fonts.numeric)
                            .foregroundStyle(Color.pnTextSecondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(.horizontal, Token.Spacing.s4)
    }

    private var elapsedStart: Date? {
        model.isImportInFlight ? model.importStartedAt : nil
    }

    private var progressSpokenValue: String {
        let percent = Int((model.progress?.fraction ?? 0) * 100)
        let stage = model.progress?.stage.displayTitle ?? "preparing"
        return "\(percent) percent, stage: \(stage)"
    }

    private var detailLine: some View {
        Text(model.progress?.detail ?? "Preparing…")
            .font(Token.Fonts.caption)
            .foregroundStyle(Color.pnTextSecondary)
            .lineLimit(1)
            .accessibilityLabel("Detail: \(model.progress?.detail ?? "preparing")")
    }

    private var cancelButton: some View {
        Button {
            model.cancelImport()
        } label: {
            if case .cancelling = model.phase {
                Text("Cancelling…").frame(maxWidth: .infinity)
            } else {
                Text("Cancel import").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .disabled(model.phase == .cancelling)
        .accessibilityHint("Nothing partial is saved if you cancel.")
    }

    private func elapsedText(since start: Date, at now: Date) -> String {
        let interval = max(0, now.timeIntervalSince(start))
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%d:%02d elapsed", minutes, seconds)
    }

    private func doneView(_ title: String) -> some View {
        VStack(spacing: Token.Spacing.s5) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.inTune)
                .accessibilityHidden(true)
            Text("Added to Library")
                .font(Token.Fonts.heading)
            Text(title)
                .font(Token.Fonts.body)
                .foregroundStyle(Color.pnTextSecondary)
            Text("Mixing and per-part learning open from the song's page.")
                .font(Token.Fonts.caption)
                .foregroundStyle(Color.pnTextSecondary)
                .multilineTextAlignment(.center)
            // J-206: the import-pass numbers the M2 gate records (separation
            // RTF, peak footprint, thermal). Copyable so the demo script can
            // paste them into the QUEUE LOG verbatim.
            if let metrics = model.metrics {
                VStack(spacing: Token.Spacing.s1) {
                    Text(ImportMetricsFormatter.summary(metrics))
                        .font(Token.Fonts.caption)
                        .foregroundStyle(Color.pnTextSecondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    Text(model.engineKind.statusLine)
                        .font(Token.Fonts.caption)
                        .foregroundStyle(model.engineKind.isReal ? Color.pnTextSecondary : Color.octaveWarn)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, Token.Spacing.s4)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Import metrics: \(ImportMetricsFormatter.summary(metrics))")
            }
            Spacer()
            Button {
                model.reset()
            } label: {
                Text("Done").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func failureView(_ error: ImportError) -> some View {
        VStack(spacing: Token.Spacing.s5) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.octaveWarn)
                .accessibilityHidden(true)
            Text(error.title)
                .font(Token.Fonts.heading)
            Text(error.recoverySuggestion)
                .font(Token.Fonts.body)
                .foregroundStyle(Color.pnTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Token.Spacing.s4)
            Spacer()
            Button {
                model.reset()
            } label: {
                Text("OK").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

// MARK: - Stage row state (display-only mapping)

private enum StageRowState {
    case pending, active, done

    var icon: String {
        switch self {
        case .pending: return "circle"
        case .active: return "circle.dotted"
        case .done: return "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .pending: return Color.pnTextSecondary
        case .active: return Color.pnAccent
        case .done: return Color.inTune
        }
    }

    var spokenLabel: String {
        switch self {
        case .pending: return "waiting"
        case .active: return "in progress"
        case .done: return "done"
        }
    }

    func caption(for stage: ImportStage) -> String {
        switch self {
        case .pending: return "waiting"
        case .active: return "running…"
        case .done:
            switch stage {
            case .decoding: return "44.1 kHz mix ready"
            case .separating: return "vocals + instrumental"
            case .assembling: return "bundle written"
            }
        }
    }
}

extension ImportStage {
    /// User-facing stage titles (UX §5.1 wording folded onto C-8 stages).
    var displayTitle: String {
        switch self {
        case .decoding: return "Decode"
        case .separating: return "Remove instruments"
        case .assembling: return "Build song bundle"
        }
    }
}

extension ImportThermalGate.Advice {
    var isDeferred: Bool {
        if case .deferRecommended = self { return true }
        return false
    }
}
