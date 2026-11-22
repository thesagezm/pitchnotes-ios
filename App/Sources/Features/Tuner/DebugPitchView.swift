import SwiftUI
import EngineCore
import PitchLogic
import UIKit

// DebugPitchView (J-103, swapped at J-105) — live pitch debug screen for the
// M1 device demo and Paul's BENCHMARKS.md readings: raw hz / confidence /
// loudness plots, RTF meter, engine identity (C-6.0), thread + device info.
// A human reads latency/RTF straight off it (AC).
//
// J-105 honesty: the engine under measurement is the REAL LivePitchFacade
// ribbon path (RibbonEngine MPM/YIN, P-102/P-105) on hop-aligned silence
// chunks — real DSP cost, honest unvoiced output, identity read off the
// frames themselves. Real mic capture joins when MicCapture wires into the
// app target (Leto's X-011a re-wiring, X-013 fixes on origin/paul); the
// grading source (SwiftF0, 176 ms) is post-hoc only — never a live path.

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

    // MARK: - Engine (C-6.0 identity — real facade, J-105)

    private var engineSection: some View {
        Section {
            LabeledRow("ribbon source (live)", debug.ribbonSourceRow)
            LabeledRow("grading source", debug.gradingSourceRow)
            LabeledRow("frame engine_id", debug.engineIDDisplay)
            LabeledRow("frame lookahead_ms", debug.lookaheadDisplay)
            LabeledRow("hop", "16 ms grid (C-2.4)")
            LabeledRow("budget", "< 100 ms end-to-end (§8)")
        } header: {
            Text("Engine")
        } footer: {
            Text("J-105: the real LivePitchFacade (P-105) drives this screen — the RTF below is the REAL ribbon (MPM/YIN) call on hop-aligned silence chunks; real mic capture joins when MicCapture wires into the target (X-011a). The grading source is post-hoc only — never a live path (C-6.0).")
        }
    }

    // MARK: - RTF meter (read off the screen for BENCHMARKS.md)

    private var rtfSection: some View {
        Section("Real-time factor (ribbon call ÷ 16 ms hop)") {
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

    struct Sample {
        let t: Double
        let hz: Double
        let confidence: Double
        let loudness_db: Double
        let callMs: Double
    }

    /// The REAL live engine (J-105). The grading seam is the honest zero
    /// placeholder until PitchORT wires the ORT inference (X-008) — the
    /// grading path is post-hoc only (C-6.0) and never runs in this loop.
    private let facade = LivePitchFacade(swiftf0Inference: PlaceholderSwiftF0Inference(),
                                         vadInference: nil)

    @Published private(set) var samples: [Sample] = []
    @Published private(set) var rtfEMA: Double = 0
    @Published private(set) var rtfWorst: Double = 0
    @Published private(set) var callEMA_ms: Double = 0
    @Published private(set) var framesPerSec: Double = 0
    /// C-6.0 identity read off the REAL frames (v0.1 fields).
    @Published private(set) var engineID = ""
    @Published private(set) var lookaheadMs: Int?

    var sampleCount: Int { samples.count }
    /// Declared C-6.0 sources (facade props — the contract identity).
    var ribbonSourceRow: String { "\(facade.ribbonSource.rawValue) · 0 ms · live" }
    var gradingSourceRow: String { "\(facade.gradingSource.rawValue) · \(LivePitchFacade.gradingLookaheadMs) ms · post-hoc (M2/M4)" }
    /// Observed identity (last real frame; declared values until frames flow).
    var engineIDDisplay: String { engineID.isEmpty ? facade.ribbonSource.rawValue : engineID }
    var lookaheadDisplay: String { lookaheadMs.map { "\($0) ms" } ?? "0 ms (declared)" }

    /// Plot series (last ~8 s, ~500 samples).
    var hzSeries: [Double] { samples.suffix(500).map(\.hz) }
    var confidenceSeries: [Double] { samples.suffix(500).map(\.confidence) }
    var loudnessSeries: [Double] { samples.suffix(500).map(\.loudness_db) }

    static let windowSeconds: Double = 8.0
    private var consumeTask: Task<Void, Never>?

    func start() {
        guard consumeTask == nil else { return }
        // Own loop (not RibbonFrameSource) so the ENGINE CALL itself is timed:
        // RTF = ribbonFrame duration ÷ 16 ms hop — the number a human reads
        // for BENCHMARKS.md. J-105: this measures the REAL RibbonEngine NSDF
        // (one hop of silence per call — real work, honest unvoiced frames).
        let facade = self.facade
        let silence = [Float](repeating: 0, count: Int(RibbonSpec.hop))
        let started = Date()
        consumeTask = Task { [weak self] in
            var lastIngest = started
            while !Task.isCancelled {
                let t0 = Date()
                let chunk = MicChunk(samples: silence, sampleRate: RibbonSpec.sampleRate,
                                     captureTime_s: t0.timeIntervalSince(started))
                // C-6.0: the CAUSAL ribbon call — never the grading path.
                let frame = facade.ribbonFrame(chunk)
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
        engineID = frame.engine_id
        lookaheadMs = frame.lookahead_ms

        rtfEMA = rtfEMA == 0 ? rtf : rtfEMA * 0.9 + rtf * 0.1
        rtfWorst = max(rtfWorst * 0.995, rtf) // decayed window max
        callEMA_ms = callEMA_ms == 0 ? callMs : callEMA_ms * 0.9 + callMs * 0.1
        let eta = framesEMA == 0 ? max(hopWall, 0.001) : framesEMA * 0.9 + max(hopWall, 0.001) * 0.1
        framesEMA = eta
        framesPerSec = 1.0 / eta
    }

    private var framesEMA: Double = 0
}
