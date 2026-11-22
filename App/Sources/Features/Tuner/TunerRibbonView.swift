import SwiftUI
import EngineCore
import PitchLogic

// TunerRibbonView (J-101) — the M1 deliverable, rendered per Docs/UX.md §3:
// scrolling cents ribbon (90 px/s, playhead at 30%), semitone gridlines with
// octave labels, reference bars with tolerance bands (±50 default, ±25/±10
// presets), live trace colored by §3.4 state, fixed-position numeric readout
// with correction arrows, part chips consuming the C-6.1 presets, and the
// octave-equivalence toggle. VoiceOver gets the ≤ 1 Hz spoken state (§7);
// colors never carry meaning alone (arrows + words do).
//
// M1 renders the MockEngine singer (demo scenario selectable — the device
// demo exercises flat/sharp/octave/vibrato without a human singing). The real
// LivePitchEngine ribbon source (P-105, D-17 causal MPM/YIN) swaps behind
// RibbonFrameSource with ZERO view changes (CONTRACTS C-6).

struct TunerRibbonView: View {
    @StateObject private var model = RibbonModel()
    @StateObject private var audio = AudioSessionController()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    // UX §3.2 zoom tokens (single definition here until Token gains them in M2).
    private let pps: CGFloat = 90            // pixels per second
    private let playheadFraction: CGFloat = 0.3

    var body: some View {
        VStack(spacing: Token.Spacing.s3) {
            MicAccessBanners(audio: audio) // J-102: prompt / denied / interruption / headphones
            partChips
            ribbon
            controls
            MicMeterRow(audio: audio)
            LatencyStubRow()
            Text("Preview: MockEngine singer (P-001) and mock input level (P-104 wires the real mic tap). This view will not change at the swap.")
                .font(Token.Fonts.caption)
                .foregroundStyle(Color.pnTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Token.Spacing.s4)
        .onAppear {
            model.reduceMotion = reduceMotion
            model.start()
            audio.startObserving()
            if audio.flow.gate == .ready { audio.startLevelMeter() }
        }
        .onDisappear {
            model.stop()
            audio.stopObserving()
            audio.stopLevelMeter()
        }
        .onChange(of: reduceMotion) { newValue in model.reduceMotion = newValue }
        .onChange(of: audio.flow.gate) { gate in
            // Level meter follows permission/interruption state (J-102).
            switch gate {
            case .ready: audio.startLevelMeter()
            default: audio.stopLevelMeter()
            }
        }
    }

    // MARK: - Ribbon canvas (§3.3 vertical mapping, §3.2 time model)

    private var ribbon: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
                Canvas { context, size in
                    draw(in: &context, size: size)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color.pnSurface, in: RoundedRectangle(cornerRadius: Token.Radius.card))
        .overlay(alignment: .topTrailing) { readout.padding(Token.Spacing.s3) }
        .opacity(model.centerIsHeld ? 0.85 : 1.0) // §3.3: held window dims
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.spoken)
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// Pure draw-time math (§3.2/§3.3): cents→y (linear, barH per semitone),
    /// time→x (pps, playhead anchor). No model access — values snapshot in.
    private struct Geometry {
        let size: CGSize
        let centerCents: Double
        let tNow: Double
        let barH: CGFloat
        let pps: CGFloat
        let playheadX: CGFloat

        func y(_ cents: Double) -> CGFloat {
            size.height / 2 - CGFloat((cents - centerCents) / 100.0) * barH
        }
        func x(_ t: Double) -> CGFloat {
            playheadX - CGFloat(tNow - t) * pps
        }
        /// Visible pitch span in cents (± around center).
        var halfSpanCents: Double { Double((size.height / 2) / barH) * 100 }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let geo = Geometry(
            size: size,
            centerCents: model.centerCents,
            tNow: model.windowTime,
            barH: min(CGFloat(22), size.height / 24), // §3.3 barH token, scaled on short layouts
            pps: pps,
            playheadX: size.width * playheadFraction)
        drawGrid(&context, geo)
        drawBars(&context, geo)
        drawTrace(&context, geo)
        drawCursor(&context, geo)
    }

    /// Semitone gridlines; octave (C) lines heavier + labeled (§3.3).
    private func drawGrid(_ context: inout GraphicsContext, _ geo: Geometry) {
        let lowMidi = Int((geo.centerCents - geo.halfSpanCents) / 100 - 1)
        let highMidi = Int((geo.centerCents + geo.halfSpanCents) / 100 + 1)
        for midi in max(0, lowMidi)...min(127, highMidi) {
            let lineY = geo.y(Double(midi) * 100)
            guard lineY >= -geo.barH, lineY <= geo.size.height + geo.barH else { continue }
            let isOctave = midi % 12 == 0
            var path = Path()
            path.move(to: CGPoint(x: 0, y: lineY))
            path.addLine(to: CGPoint(x: geo.size.width, y: lineY))
            context.stroke(path,
                           with: .color(isOctave ? Color.pnTextSecondary.opacity(0.45) : Color.pnTrack),
                           lineWidth: isOctave ? 1.5 : 0.75)
            if isOctave {
                context.draw(
                    Text(PitchMath.noteName(forMidi: midi))
                        .font(.caption2)
                        .foregroundColor(Color.pnTextSecondary),
                    at: CGPoint(x: geo.playheadX + 8, y: lineY - 9),
                    anchor: .leading)
            }
        }
    }

    /// Reference bars + tolerance bands (§3.4 band = 2·tol strip on each bar;
    /// §3.7 low-confidence bars at 70% + dashed border).
    private func drawBars(_ context: inout GraphicsContext, _ geo: Geometry) {
        let tol = CGFloat(model.tolerance.cents) / 100.0 * geo.barH
        for bar in model.referenceBars {
            let bx = geo.x(bar.start_s)
            let bw = CGFloat(bar.end_s - bar.start_s) * geo.pps
            guard bx + bw >= 0, bx <= geo.size.width else { continue }

            let bandRect = CGRect(x: bx,
                                  y: geo.y(bar.absoluteCents + model.tolerance.cents),
                                  width: bw, height: 2 * tol)
            context.fill(Path(roundedRect: bandRect, cornerRadius: 3),
                         with: .color(Color.pnAccent.opacity(colorScheme == .dark ? 0.30 : 0.22)))

            let barHeight = geo.barH * 0.86
            let barRect = CGRect(x: bx,
                                 y: geo.y(bar.absoluteCents) - barHeight / 2,
                                 width: bw, height: barHeight)
            let lowConf = bar.confidence < 0.6
            context.fill(Path(roundedRect: barRect, cornerRadius: 4),
                         with: .color(Color.referenceBar.opacity(lowConf ? 0.7 : 1.0)))
            if lowConf {
                context.stroke(Path(roundedRect: barRect, cornerRadius: 4),
                               with: .color(Color.pnTextSecondary),
                               style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
    }

    /// Live trace: merged same-state runs, dashed when low confidence (§3.4/§3.7);
    /// unvoiced frames break the line (§3.4).
    private func drawTrace(_ context: inout GraphicsContext, _ geo: Geometry) {
        var runPath: Path?
        var runState: RibbonState = .unvoiced
        var runLow = false
        var lastPoint: CGPoint?

        func flushRun() {
            if let path = runPath {
                let styled = StrokeStyle(lineWidth: 2.5, lineCap: .round,
                                         dash: runLow ? [5, 3] : [])
                context.stroke(path,
                               with: .color(Self.color(for: runState)),
                               style: styled)
            }
            runPath = nil
        }

        for point in model.trace {
            guard let cents = point.cents else {
                flushRun() // unvoiced → trace break
                lastPoint = nil
                continue
            }
            let p = CGPoint(x: geo.x(point.t), y: geo.y(cents))
            if lastPoint == nil || point.state != runState || point.lowConfidence != runLow {
                flushRun()
                runState = point.state
                runLow = point.lowConfidence
                var path = Path()
                if let lp = lastPoint { path.move(to: lp) }
                path.addLine(to: p)
                runPath = path
            } else {
                runPath?.addLine(to: p)
            }
            lastPoint = p
        }
        flushRun()
    }

    /// Live cursor at the playhead (§3.3); unvoiced → hollow gray dot.
    private func drawCursor(_ context: inout GraphicsContext, _ geo: Geometry) {
        if let current = model.trace.last, let cents = current.cents {
            let rect = CGRect(x: geo.playheadX - 6, y: geo.y(cents) - 6, width: 12, height: 12)
            context.fill(Path(ellipseIn: rect),
                         with: .color(Self.color(for: current.state)))
            context.stroke(Path(ellipseIn: rect), with: .color(Color.pnSurface), lineWidth: 1.5)
        } else {
            let rect = CGRect(x: geo.playheadX - 5, y: geo.size.height / 2 - 5, width: 10, height: 10)
            context.stroke(Path(ellipseIn: rect),
                           with: .color(Color.unvoiced.opacity(0.45)),
                           lineWidth: 1.5)
        }
    }

    /// §3.4 state colors — semantic tokens only (colors never carry meaning
    /// alone; arrows + words accompany them).
    static func color(for state: RibbonState) -> Color {
        switch state {
        case .inTune: return .inTune
        case .flat: return .flat
        case .sharp: return .sharp
        case .unvoiced: return .unvoiced
        }
    }

    // MARK: - Readout (fixed position — never shifts, §3.4)

    private var readout: some View {
        HStack(spacing: Token.Spacing.s2) {
            if let r = model.reading, r.state != .unvoiced {
                if r.direction == .up {
                    Image(systemName: "arrow.up").foregroundStyle(Color.flat) // sing higher
                } else if r.direction == .down {
                    Image(systemName: "arrow.down").foregroundStyle(Color.sharp) // sing lower
                }
                Text(r.readoutText)
                    .font(Token.Fonts.numeric)
                    .fontWeight(.semibold)
                    .foregroundStyle(Self.color(for: r.state))
                if let badge = r.octaveBadge {
                    Text(badge == .up ? "8va" : "8vb")
                        .font(Token.Fonts.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.octaveWarn)
                        .padding(.horizontal, Token.Spacing.s2)
                        .padding(.vertical, 2)
                        .background(Color.octaveWarn.opacity(0.15), in: Capsule())
                        .accessibilityLabel(badge == .up ? "one octave up" : "one octave down")
                }
            } else {
                Text("unvoiced")
                    .font(Token.Fonts.numeric)
                    .foregroundStyle(Color.unvoiced)
            }
        }
        .padding(.horizontal, Token.Spacing.s3)
        .padding(.vertical, Token.Spacing.s2)
        .background(.thinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    // MARK: - Part chips (§3.6, C-6.1 presets via PitchLogic)

    private var partChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Token.Spacing.s2) {
                let mockParts: [Part] = [.t1, .t2, .baritenor, .baritone, .bass] // C-1 sortOrder
                ForEach(mockParts, id: \.self) { part in
                    chipButton(part: part)
                }
            }
            .padding(.vertical, Token.Spacing.s1)
        }
    }

    private func chipButton(part: Part) -> some View {
        let selected = model.selectedPart == part
        let range = PartRangeChips.range(for: part)
        let label = selected
            ? (range?.displayName ?? part.displayName)
            : part.displayName
        return Button {
            model.selectedPart = part
        } label: {
            Text(label)
                .font(Token.Fonts.caption)
                .fontWeight(selected ? .bold : .regular)
                .foregroundStyle(selected ? Color.pnAccent : Color.pnTextSecondary)
                .padding(.horizontal, Token.Spacing.s3)
                .padding(.vertical, Token.Spacing.s2)
                .background(selected ? Color.pnAccent.opacity(0.14) : Color.pnTrack, in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44) // HIG hit target (§0.4)
        .accessibilityLabel(range.map { "\(part.displayName), \($0.presetName) range" } ?? part.displayName)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - Controls (bottom third, §0.4)

    private var controls: some View {
        VStack(spacing: Token.Spacing.s2) {
            Picker("Tolerance", selection: $model.tolerance) {
                ForEach(RibbonTolerance.allCases) { t in
                    Text(t.label).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Tolerance band")

            HStack(spacing: Token.Spacing.s3) {
                // J-FIX-104: mode selection is a segmented Picker — ONE tap
                // toggles demo↔liveMic in EITHER direction, with fixed hit
                // targets. The M1 defect had both modes inside one Menu whose
                // content mutated on selection (taps raced the relayout and
                // were dropped; →demo unreliable). Wiring data + regression
                // tests live in PitchLogic (RibbonSourceMode).
                Picker("Source", selection: $model.sourceMode) {
                    ForEach(RibbonSourceMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityLabel("Pitch source")
                .accessibilityHint(model.sourceMode == .demo
                    ? "Scripted demo singer. Tap Live mic to sing into the microphone."
                    : "Real pitch engine on microphone input. Tap Demo for the scripted singer.")

                if model.sourceMode.showsScenarioPicker {
                    // J-105 demo-scenario menu — demo mode ONLY (it lists the
                    // 8 scripted singer states; liveMic has no script). Kept
                    // OUT of the mode selector so switching modes is always a
                    // single reliable tap (J-FIX-104). The menu stays until
                    // real capture is the only path (X-011a done; removal is a
                    // one-line change, UX §3.9).
                    Menu {
                        ForEach(MockScenario.allCases, id: \.self) { s in
                            Button(s.menuLabel) { model.demoScenario = s }
                        }
                    } label: {
                        Label(model.demoScenario.menuLabel,
                              systemImage: "person.wave.2.fill")
                            .font(Token.Fonts.caption)
                            .padding(.horizontal, Token.Spacing.s3)
                            .padding(.vertical, Token.Spacing.s2)
                            .background(Color.pnTrack, in: Capsule())
                    }
                    .accessibilityLabel("Demo singer scenario, currently \(model.demoScenario.menuLabel)")
                }
            }
        }
    }
}

// MARK: - Display formatting (view-side glue only; decisions live in RibbonMapper)

private extension RibbonReading {
    /// "E3 +12¢" numeric readout (UX §3.4).
    var readoutText: String {
        let name = PitchMath.noteName(forMidi: nearestMidi ?? 60)
        let sign = cents >= 0 ? "+" : "−"
        return "\(name) \(sign)\(Int(abs(cents).rounded()))¢"
    }
}

private extension MockScenario {
    var menuLabel: String {
        switch self {
        case .perfect: return "Perfect"
        case .flat: return "Flat −30¢"
        case .sharp: return "Sharp +35¢"
        case .octaveError: return "Octave error"
        case .silent: return "Silent"
        case .breathy: return "Breathy"
        case .lateOnset: return "Late onset"
        case .vibrato: return "Vibrato"
        }
    }
}
