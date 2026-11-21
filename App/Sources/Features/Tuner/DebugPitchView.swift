import SwiftUI
import EngineCore
import PitchLogic
import UIKit

// DebugPitchView (J-103) — live pitch debug screen for the M1 device demo and
// Paul's BENCHMARKS.md readings: raw hz / confidence / loudness plots, RTF
// meter, engine identity (C-6.0 ribbonSource vs gradingSource), thread + device
// info. A human reads latency/RTF straight off it (AC).
//
// M1 honesty: the engine under measurement is the MOCK (P-001) — RTF numbers
// are a real baseline of the mock path, and the P-105 facade swaps the real
// engines in behind the same seam with zero view changes. engine_id /
// lookahead_ms display placeholders until the v0.1 PitchFrame fields exist in
// EngineCore (they arrive with P-105).

struct DebugPitchView: View {
    @StateObject private var debug = DebugPitchModel()

    var body: some View {
        Form {
            engineSection
            rtfSection
            plotsSection
            deviceSection
        }
        .scrollContentBackground(.hidden)
        .background(Color.pnBackground)
        .navigationTitle("Live pitch debug")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { debug.start() }
        .onDisappear { debug.stop() }
    }

    // MARK: - Engine (C-6.0 facade selector — activates at P-105)

    private var engineSection: some View {
        Section {
            Picker("Source", selection: .constant(DebugPitchModel.Source.ribbon)) {
                Text("Ribbon (causal)").tag(DebugPitchModel.Source.ribbon)
                Text("Grading (SwiftF0)").tag(DebugPitchModel.Source.grading)
            }
            .pickerStyle(.segmented)
            .disabled(true) // P-105: facade swap — both sources exist behind RibbonFrameSource
            LabeledRow("engine_id", debug.engineIDDisplay)
            LabeledRow("lookahead_ms", debug.lookaheadDisplay)
            LabeledRow("hop", "16 ms grid (C-2.4)")
            LabeledRow("budget", "< 100 ms end-to-end (§8)")
        } header: {
            Text("Engine")
        } footer: {
            Text("M1 measures the MockEngine path (P-001). The selector and engine_id/lookahead_ms fields populate when the LivePitchEngine facade (P-105, contract v0.1 C-6) lands.")
        }
    }

    // MARK: - RTF meter (read off the screen for BENCHMARKS.md)

    private var rtfSection: some View {
        Section("Real-time factor (engine call ÷ 16 ms hop)") {
            LabeledRow("RTF (EMA)", String(format: "%.3f", debug.rtfEMA))
            LabeledRow("RTF (worst, window)", String(format: "%.3f", debug.rtfWorst))
            LabeledRow("engine call (EMA)", String(format: "%.3f ms", debug.callEMA_ms))
            LabeledRow("frames/s", String(format: "%.0f", debug.framesPerSec))
            LabeledRow("RTF target", "≤ 0.3 (AGENTS §8)")
            ProgressView(value: min(debug.rtfEMA, 1.0))
                .tint(debug.rtfEMA <= 0.3 ? Color.inTune : Color.octaveWarn)
                .accessibilityLabel("RTF meter")
                .accessibilityValue(String(format: "%.3f of 1.0", debug.rtfEMA))
        }
    }

    // MARK: - Raw plots (hz / confidence / loudness)

    private var plotsSection: some View {
        Section("Live frames") {
            PlotStrip(title: "hz", values: debug.hzSeries, unit: "Hz")
            PlotStrip(title: "confidence", values: debug.confidenceSeries, unit: "")
            PlotStrip(title: "loudness_db", values: debug.loudnessSeries, unit: "dB")
            LabeledRow("frames captured", "\(debug.sampleCount)")
        }
    }

    // MARK: - Device info

    private var deviceSection: some View {
        Section("Device") {
            LabeledRow("model", UIDevice.current.model)
            LabeledRow("OS", UIDevice.current.systemVersion)
            LabeledRow("CPU cores", "\(ProcessInfo.processInfo.activeProcessorCount)")
            LabeledRow("engine thread", "off-main, userInitiated task")
            LabeledRow("thermal state", Self.thermalName(ProcessInfo.processInfo.thermalState))
        }
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - Pieces

private struct LabeledRow: View {
    let name: String
    let value: String
    init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
    var body: some View {
        HStack {
            Text(name).font(Token.Fonts.body)
            Spacer()
            Text(value)
                .font(Token.Fonts.numeric)
                .foregroundStyle(Color.pnTextSecondary)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name): \(value)")
    }
}

/// One mini strip chart: last N samples, min–max autoscaled (hz) or 0–1
/// (confidence) / fixed dB range (loudness).
struct PlotStrip: View {
    let title: String
    let values: [Double]
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s1) {
            HStack {
                Text(title).font(Token.Fonts.caption).fontWeight(.semibold)
                Spacer()
                if let last = values.last {
                    Text(unit.isEmpty ? String(format: "%.2f", last) : String(format: "%.1f %@", last, unit))
                        .font(Token.Fonts.numeric)
                        .foregroundStyle(Color.pnTextSecondary)
                }
            }
            Canvas { context, size in
                guard values.count > 1 else { return }
                let lo = unit == "Hz" ? (values.min() ?? 0) : (unit == "dB" ? -100 : 0)
                let hi = unit == "Hz" ? (values.max() ?? 1) : (unit == "dB" ? -10 : 1)
                let span = max(hi - lo, 0.0001)
                var path = Path()
                for (i, v) in values.enumerated() {
                    let x = size.width * CGFloat(i) / CGFloat(values.count - 1)
                    let y = size.height * (1 - CGFloat((v - lo) / span))
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(path, with: .color(.pnAccent), lineWidth: 1.5)
            }
            .frame(height: 44)
            .accessibilityHidden(true) // chart; the numeric readout above is the a11y value
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) plot, current \(values.last.map { String(format: "%.2f", $0) } ?? "—")")
    }
}

// MARK: - Model (measuring loop — real RTF numbers off the engine path)

@MainActor
final class DebugPitchModel: ObservableObject {

    enum Source: String {
        case ribbon = "RIBBON_MPM_YIN"   // C-6.0 rawValue — causal, D-17
        case grading = "SWIFTF0"         // C-6.0 rawValue — 176 ms lookahead
    }

    struct Sample {
        let t: Double
        let hz: Double
        let confidence: Double
        let loudness_db: Double
        let callMs: Double
    }

    @Published private(set) var samples: [Sample] = []
    @Published private(set) var rtfEMA: Double = 0
    @Published private(set) var rtfWorst: Double = 0
    @Published private(set) var callEMA_ms: Double = 0
    @Published private(set) var framesPerSec: Double = 0

    var sampleCount: Int { samples.count }
    /// C-6.0 identity: populates from real frames at P-105 (v0.1 fields).
    var engineIDDisplay: String { "— (P-105)" }
    var lookaheadDisplay: String { "— (P-105: 0 ms ribbon / 176 ms grading)" }

    /// Plot series (last ~8 s, ~500 samples).
    var hzSeries: [Double] { samples.suffix(500).map(\.hz) }
    var confidenceSeries: [Double] { samples.suffix(500).map(\.confidence) }
    var loudnessSeries: [Double] { samples.suffix(500).map(\.loudness_db) }

    static let windowSeconds: Double = 8.0
    private var consumeTask: Task<Void, Never>?

    func start() {
        guard consumeTask == nil else { return }
        // Own loop (not MockRibbonFrameSource) so the ENGINE CALL itself is
        // timed: RTF = livePitch duration ÷ 16 ms hop — the number a human
        // reads for BENCHMARKS.md. Mock calls are array-index cheap (< 1 ms);
        // the real engines (P-105) swap in behind the same measurement.
        let engine = MockEngine(scenario: .vibrato, seed: 0x5103, referencePart: .t2)
        let started = Date()
        consumeTask = Task { [weak self] in
            var lastIngest = started
            while !Task.isCancelled {
                let t0 = Date()
                let chunk = MicChunk(samples: [], sampleRate: 16000,
                                     captureTime_s: t0.timeIntervalSince(started))
                let frame = engine.livePitch(chunk)
                let callMs = Date().timeIntervalSince(t0) * 1000
                let hopWall = t0.timeIntervalSince(lastIngest)
                lastIngest = t0
                self?.ingest(frame, callMs: callMs, hopWall: hopWall)
                let next = t0.addingTimeInterval(EngineContract.hopSeconds)
                let nap = next.timeIntervalSinceNow
                if nap > 0 { try? await Task.sleep(nanoseconds: UInt64(nap * 1_000_000_000)) }
            }
        }
    }

    func stop() {
        consumeTask?.cancel()
        consumeTask = nil
    }

    private func ingest(_ frame: PitchFrame, callMs: Double, hopWall: Double) {
        let rtf = callMs / (EngineContract.hopSeconds * 1000) // engine time ÷ audio time
        samples.append(Sample(t: frame.t, hz: frame.hz,
                              confidence: frame.confidence,
                              loudness_db: frame.loudness_db,
                              callMs: callMs))
        if samples.count > 700 { samples.removeFirst(samples.count - 700) }

        rtfEMA = rtfEMA == 0 ? rtf : rtfEMA * 0.9 + rtf * 0.1
        rtfWorst = max(rtfWorst * 0.995, rtf) // decayed window max
        callEMA_ms = callEMA_ms == 0 ? callMs : callEMA_ms * 0.9 + callMs * 0.1
        let eta = framesEMA == 0 ? max(hopWall, 0.001) : framesEMA * 0.9 + max(hopWall, 0.001) * 0.1
        framesEMA = eta
        framesPerSec = 1.0 / eta
    }

    private var framesEMA: Double = 0
}
