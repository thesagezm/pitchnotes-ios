import SwiftUI
import PitchLogic
import EngineCore

// SessionView (J-402) — the session host (UX §5.4): the ribbon's reference
// bars with the live hit markers, the count-in ring, the pause controls, the
// phrase micro-banner, and the DONE → Results screen (grade, heatmap strip,
// the ≤ 3 weakest phrases, retry).
//
// THE RIBBON IS §3.9's, unchanged in shape — the session adds the markers
// row and the phase chrome around it, never a re-design. THE HONESTY: the
// phase chrome says which reference grades (C-14) and the demo says it is a
// demo (AGENTS §11).
struct SessionView: View {

    @ObservedObject var model: LearnSessionModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s3) {
            header
            switch model.phase {
            case .ready:
                EmptyView()
            case .countIn(let remaining):
                countInRing(remaining: remaining)
                controlsRow
            case .active:
                markersRow
                controlsRow
            case .paused:
                pausedBanner
                pausedControls
            case .done:
                ResultsSection(model: model,
                               onRetryWeak: { model.retryWeakPhrases() },
                               onRetryAll: { model.retryAll() },
                               onClose: onClose)
            case .discarded:
                Text("Session discarded — nothing was graded or saved.")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
                Button("Back") { onClose() }
                    .buttonStyle(.bordered)
            }
            if let error = model.errorMessage {
                Text(error).font(Token.Fonts.caption).foregroundStyle(Color.octaveWarn)
            }
        }
        .padding(Token.Spacing.s4)
        .accessibilityElement(children: .contain)
        .onDisappear { model.tearDownAudio() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s1) {
            Text("\(model.songTitle) · \(model.selectedPart.displayName)")
                .font(Token.Fonts.heading)
            Text("Grading reference: \(referenceName). \(model.isDemo ? "DEMO — synthetic stream, not a human singer." : "")")
                .font(Token.Fonts.caption)
                .foregroundStyle(Color.pnTextSecondary)
        }
    }

    private var referenceName: String {
        switch model.gradingReference.source {
        case .correctionOverlay: return "your corrections (they win)"
        case .scoreInformed: return "the score (aligned)"
        case .heuristic: return "the detected notes — heuristic"
        }
    }

    /// Dynamic-type-scaled count-in numeral (§12 audit: every fixed size scales).
    @ScaledMetric(relativeTo: .largeTitle) private var countInSize: CGFloat = 64

    private func countInRing(remaining: Int) -> some View {
        VStack(spacing: Token.Spacing.s2) {
            Text("\(remaining)")
                .font(.system(size: countInSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .accessibilityLabel("Count-in beat \(remaining)")
            Text("Get ready — grading starts at beat 0")
                .font(Token.Fonts.caption)
                .foregroundStyle(Color.pnTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(Token.Spacing.s4)
    }

    /// The hit markers (§5.4): one dot per reference note whose window has
    /// closed — green hit / orange miss / hollow silent.
    private var markersRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Token.Spacing.s2) {
                let notes = model.composed[model.selectedPart]?.notes ?? []
                ForEach(notes.indices, id: \.self) { index in
                    markerDot(index: index, note: notes[index])
                }
            }
        }
        .frame(height: 36)
        .accessibilityLabel("Hit markers so far")
    }

    @ViewBuilder
    private func markerDot(index: Int, note: Note) -> some View {
        let marker = model.markers[index]
        Circle()
            .stroke(markerColor(marker), lineWidth: 2)
            .background(Circle().fill(markerFill(marker)))
            .frame(width: 22, height: 22)
            .accessibilityLabel(markerLabel(index: index, note: note, marker: marker))
    }

    private func markerColor(_ marker: SessionFeedback.Marker?) -> Color {
        switch marker {
        case .hit: return .inTune
        case .miss: return .flat
        case .silent: return .unvoiced
        case nil: return .referenceBar
        }
    }

    private func markerFill(_ marker: SessionFeedback.Marker?) -> Color {
        switch marker {
        case .hit: return .inTune
        default: return .clear
        }
    }

    private func markerLabel(index: Int, note: Note,
                             marker: SessionFeedback.Marker?) -> String {
        let name = PitchMath.noteName(forMidi: note.midi)
        switch marker {
        case .hit: return "Note \(index + 1), \(name): hit"
        case .miss(let cents):
            return "Note \(index + 1), \(name): miss, \(Int(cents) >= 0 ? "+" : "")\(Int(cents)) cents"
        case .silent: return "Note \(index + 1), \(name): not sung"
        case nil: return "Note \(index + 1), \(name): still open"
        }
    }

    private var controlsRow: some View {
        HStack(spacing: Token.Spacing.s2) {
            Button("Pause") { model.pause() }
                .buttonStyle(.bordered)
                .accessibilityHint("Pauses the session; graded frames are held and the reference stops.")
            Spacer()
        }
    }

    private var pausedBanner: some View {
        Text(model.pausedByInterruption
             ? "Paused by an interruption (a call or another app's audio) — nothing was graded while paused. Resume when you're ready."
             : "Paused — graded frames held; the latency setting is unchanged.")
            .font(Token.Fonts.caption)
            .foregroundStyle(Color.pnTextSecondary)
            .padding(Token.Spacing.s2)
            .frame(maxWidth: .infinity)
            .background(Color.pnSurfaceElevated)
            .accessibilityLabel(model.pausedByInterruption
                                ? "Session paused by an interruption. Resume when ready."
                                : "Session paused.")
    }

    private var pausedControls: some View {
        VStack(spacing: Token.Spacing.s2) {
            Button("Resume") { model.resume() }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Continues from where the session paused.")
            Button("Restart phrase") { model.restartPhrase() }
                .buttonStyle(.bordered)
                .accessibilityHint("Rewinds to the start of the current phrase and redoes it.")
            Button("Quit (discard)") { model.quit() }
                .buttonStyle(.bordered)
                .accessibilityHint("Ends the session without grading or saving anything.")
        }
    }
}

// MARK: - Results (§6.3: grade, heatmap strip, weakest phrases, retry)

struct ResultsSection: View {

    @ObservedObject var model: LearnSessionModel
    let onRetryWeak: () -> Void
    let onRetryAll: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s3) {
            if let result = model.result {
                gradeHeader(result)
                HeatmapStrip(result: result)
                weakPhrases(result)
                environmentFootnote(result)
            } else {
                ProgressView("Grading…")
            }
            HStack(spacing: Token.Spacing.s2) {
                Button("Retry weak phrases", action: onRetryWeak)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.weakPhrases.isEmpty)
                Button("Retry all", action: onRetryAll).buttonStyle(.bordered)
                Button("Done", action: onClose).buttonStyle(.bordered)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Dynamic-type-scaled grade numeral (§12 audit).
    @ScaledMetric(relativeTo: .largeTitle) private var gradeSize: CGFloat = 56

    private func gradeHeader(_ result: SessionResult) -> some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s1) {
            HStack(alignment: .firstTextBaseline, spacing: Token.Spacing.s2) {
                Text(result.grade.map { "\($0.rawValue)" } ?? "—")
                    .font(.system(size: gradeSize, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.pnAccent)
                    .accessibilityLabel("Grade \(result.grade?.rawValue ?? "not available")")
                if let accuracy = result.accuracy {
                    Text("overall \(percent(accuracy.overall)) · steady \(percent(accuracy.steady)) · transition \(percent(accuracy.transition))")
                        .font(Token.Fonts.numeric)
                        .foregroundStyle(Color.pnTextSecondary)
                }
            }
            // D-54 §1: a grade from a subset never looks like a grade of the whole.
            if let summary = result.notAssessable, summary.total > 0 {
                Text("\(summary.total) note(s) not assessable (unassigned \(summary.byReason.unassigned), no live frames \(summary.byReason.noLiveFrames)) — they contributed no score.")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.octaveWarn)
            }
            Text("Reference: \(result.gradingReference?.source.rawValue ?? "heuristic") · tuning \(result.tuningCents ?? 0)c · latency \(result.latencyOffset_ms ?? 0) ms · all numbers synthetic (demo/fixtures), not device-verified.")
                .font(Token.Fonts.caption)
                .foregroundStyle(Color.pnTextSecondary)
        }
    }

    private func weakPhrases(_ result: SessionResult) -> some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s1) {
            Text("Weakest phrases").font(Token.Fonts.caption)
            let weak = model.weakPhrases
            if weak.isEmpty {
                Text("None below the retry threshold — nothing queued.").font(Token.Fonts.caption)
            } else {
                ForEach(weak, id: \.phraseIndex) { phrase in
                    Text("Phrase \(phrase.phraseIndex + 1): \(Int((phrase.score * 100).rounded()))%")
                        .font(Token.Fonts.numeric)
                }
            }
        }
    }

    private func environmentFootnote(_ result: SessionResult) -> some View {
        Text("Graded with tolerance ±\(result.config?.toleranceCents ?? 50) cents, octave equivalence \(result.config?.octaveEquivalence == true ? "on" : "off"). The config travels with the session.")
            .font(Token.Fonts.caption)
            .foregroundStyle(Color.pnTextSecondary)
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int((value * 100).rounded()))%"
    }
}

/// The per-note heatmap strip (§12.4): one cell per graded note, coloured by
/// the marker class, tap → the note's honest detail line.
struct HeatmapStrip: View {

    let result: SessionResult

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(result.perNote ?? [], id: \.noteIndex) { note in
                    Rectangle()
                        .fill(cellColor(note))
                        .frame(width: 14, height: 26)
                        .accessibilityLabel(cellLabel(note))
                }
            }
        }
        .frame(height: 30)
        .accessibilityElement(children: .contain)
    }

    private func cellColor(_ note: PerNoteResult) -> Color {
        if note.notAssessable == true { return .unvoiced }
        switch note.hit {
        case .some(true): return .inTune
        case .some(false): return .octaveWarn
        case nil: return .referenceBar
        }
    }

    private func cellLabel(_ note: PerNoteResult) -> String {
        if note.notAssessable == true {
            return "Note \(note.noteIndex + 1): not assessable (\(note.notAssessableReason ?? "unknown"))"
        }
        switch note.hit {
        case .some(true):
            return "Note \(note.noteIndex + 1): hit, \(Int(note.centsDeviation ?? 0)) cents, sustained \(note.sustain_ms ?? 0) ms"
        case .some(false):
            return "Note \(note.noteIndex + 1): miss, \(Int(note.centsDeviation ?? 0)) cents, coverage \(Int(((note.coverage ?? 0) * 100).rounded()))%"
        case nil:
            return "Note \(note.noteIndex + 1): no verdict"
        }
    }
}
