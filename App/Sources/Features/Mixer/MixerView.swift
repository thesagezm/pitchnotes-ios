import SwiftUI
import EngineCore
import PitchLogic

// MixerView (J-203, UX §5.3) — per-lane faders + M/S + presets, transport
// with instant seek and A/B region loop. All gain/loop DECISIONS live in
// PitchLogic (MixerModel/TransportModel, unit-tested); this view renders and
// forwards intent only.
//
// D-12 honesty copy: Focus = "others quieter" (−12 dB), never a solo promise;
// the explicit Solo button IS labeled as muting the other lanes (stems bleed
// — the caption says so).

struct MixerView: View {
    @StateObject private var player: MixerPlayer
    @Environment(\.dismiss) private var dismiss

    init(song: LibrarySong) {
        _player = StateObject(wrappedValue: MixerPlayer(song: song))
    }

    var body: some View {
        List {
            transportSection
            presetSection
            laneSection
            honestyFooter
        }
        .scrollContentBackground(.hidden)
        .background(Color.pnBackground)
        .navigationTitle(player.song.manifest.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { player.prepare() }
        .onDisappear { player.pause() }
    }

    // MARK: - Transport (instant seek; A/B region loop)

    private var transportSection: some View {
        Section {
            VStack(spacing: Token.Spacing.s2) {
                HStack {
                    Text(player.transport.position_s, format: .number.precision(.fractionLength(1)))
                        .font(Token.Fonts.numeric)
                    Spacer()
                    Text(player.resolvedDuration, format: .number.precision(.fractionLength(1)))
                        .font(Token.Fonts.numeric)
                        .foregroundStyle(Color.pnTextSecondary)
                }
                Slider(
                    value: Binding(
                        get: { player.transport.position_s },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(player.resolvedDuration, 0.001)
                )
                .accessibilityLabel("Song position")
                .accessibilityValue("\(Int(player.transport.position_s)) of \(Int(player.resolvedDuration)) seconds")

                HStack(spacing: Token.Spacing.s3) {
                    Button {
                        if player.transport.state == .playing {
                            player.pause()
                        } else {
                            player.play()
                        }
                    } label: {
                        Image(systemName: player.transport.state == .playing
                              ? "pause.circle.fill" : "play.circle.fill")
                            .font(.largeTitle)
                    }
                    .accessibilityLabel(player.transport.state == .playing ? "Pause" : "Play")

                    Button {
                        player.toggleLoopAroundCurrent()
                    } label: {
                        Label(player.transport.loop != nil ? "Loop on" : "Loop",
                              systemImage: "arrow.triangle.capsule.endpath")
                            .font(Token.Fonts.caption)
                            .fontWeight(.semibold)
                            .padding(.horizontal, Token.Spacing.s3)
                            .padding(.vertical, Token.Spacing.s2)
                            .background(
                                player.transport.loop != nil
                                    ? Color.pnAccent.opacity(0.2) : Color.pnTrack,
                                in: Capsule())
                    }
                    .accessibilityLabel("Region loop")
                    .accessibilityHint("Loops ten seconds from the current position. Tap again to release.")

                    Spacer()

                    if let loop = player.transport.loop {
                        Text(String(format: "A %.1f — B %.1f", loop.lowerBound, loop.upperBound))
                            .font(Token.Fonts.caption)
                            .foregroundStyle(Color.pnTextSecondary)
                            .accessibilityLabel("Looping from \(Int(loop.lowerBound)) to \(Int(loop.upperBound)) seconds")
                    }
                }
            }
            .padding(.vertical, Token.Spacing.s1)

            if let notice = player.backgroundNotice {
                Label(notice, systemImage: "iphone.and.arrow.forward")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
            }
        }
    }

    // MARK: - Presets (focus is the DEFAULT — D-12)

    private var presetSection: some View {
        Section("Mix preset") {
            Picker("Preset", selection: presetBinding) {
                Text(MixerPreset.focus.label).tag(0)
                Text(MixerPreset.allVoices.label).tag(1)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Mix preset")
            .accessibilityHint("Focus keeps the selected part forward and the others quieter, not silent")
        }
    }

    private var presetBinding: Binding<Int> {
        Binding(
            get: { player.mixer.preset == .focus ? 0 : 1 },
            set: { tag in
                if tag == 0 {
                    player.applyFocus(to: player.mixer.focusTarget
                        ?? player.mixer.lanes.first?.part)
                } else {
                    player.applyAllVoices()
                }
            })
    }

    // MARK: - Lanes

    private var laneSection: some View {
        Section("Stems") {
            ForEach(player.mixer.lanes) { lane in
                LaneRow(
                    lane: lane,
                    isFocusTarget: player.mixer.focusTarget == lane.part,
                    resolvedGain: player.mixer.resolvedGain(for: lane.part)) { intent in
                    switch intent {
                    case .fader(let value):
                        player.setFader(value, for: lane.part)
                    case .mute(let muted):
                        player.setMuted(muted, for: lane.part)
                    case .solo(let soloed):
                        player.setSoloed(soloed, for: lane.part)
                    case .focus:
                        player.applyFocus(to: lane.part)
                    }
                }
            }
        }
    }

    private var honestyFooter: some View {
        Section {
            Text("Focus keeps every other stem audible at −12 dB — separated stems bleed into each other, so no preset promises isolation. Solo does mute the other lanes, but bleed into the soloed stem remains. Audio is never retuned (D-22).")
                .font(Token.Fonts.caption)
                .foregroundStyle(Color.pnTextSecondary)
        }
    }
}

// MARK: - One lane row

private struct LaneRow: View {
    enum Intent {
        case fader(Double)
        case mute(Bool)
        case solo(Bool)
        case focus
    }

    let lane: MixerLane
    let isFocusTarget: Bool
    let resolvedGain: Double
    let onIntent: (Intent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s2) {
            HStack {
                Button {
                    onIntent(.focus)
                } label: {
                    HStack(spacing: Token.Spacing.s1) {
                        Image(systemName: isFocusTarget ? "person.wave.2.fill" : "person.wave.2")
                            .accessibilityHidden(true)
                        Text(lane.part.displayName)
                            .fontWeight(isFocusTarget ? .bold : .regular)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(lane.part.displayName) — make this the focus part")
                .accessibilityAddTraits(isFocusTarget ? [.isSelected] : [])

                Spacer()

                Button {
                    onIntent(.solo(!lane.isSoloed))
                } label: {
                    Text("S")
                        .fontWeight(.bold)
                        .frame(width: 32, height: 32)
                        .background(lane.isSoloed ? Color.pnAccent : Color.pnTrack, in: Circle())
                }
                .accessibilityLabel("\(lane.part.displayName) solo — mutes the other lanes; stems still bleed")
                .accessibilityAddTraits(lane.isSoloed ? [.isSelected] : [])

                Button {
                    onIntent(.mute(!lane.isMuted))
                } label: {
                    Text("M")
                        .fontWeight(.bold)
                        .frame(width: 32, height: 32)
                        .background(lane.isMuted ? Color.octaveWarn : Color.pnTrack, in: Circle())
                }
                .accessibilityLabel("\(lane.part.displayName) mute")
                .accessibilityAddTraits(lane.isMuted ? [.isSelected] : [])
            }

            Slider(value: Binding(
                get: { lane.fader },
                set: { onIntent(.fader($0)) }
            ), in: 0...1)
            .accessibilityLabel("\(lane.part.displayName) volume")
            .accessibilityValue(resolvedGain <= 0
                ? "muted"
                : "\(Int(round(resolvedGain * 100))) percent")

            Text(resolvedGain <= 0
                 ? "muted"
                 : String(format: "%.1f dB", 20.0 * log10(max(resolvedGain, 1e-6))))
                .font(Token.Fonts.caption)
                .foregroundStyle(Color.pnTextSecondary)
        }
        .padding(.vertical, Token.Spacing.s1)
    }
}
