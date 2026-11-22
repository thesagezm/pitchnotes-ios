import SwiftUI
import PitchLogic

// MicAccessView (J-102) — the mic permission + audio session UX, rendered as
// a banner stack above the ribbon plus the meter/latency rows below the
// controls. Every state is designed (UX principle 6): prompt, denied (with
// Settings deep-link), interruption (call/background), no-headphones
// guidance — and the input level meter with its M1 mock source labeled
// honestly. Latency compensation is a STUB here (real loopback calibration
// is J-403, M4 — UX §5.4).

struct MicAccessBanners: View {
    @ObservedObject var audio: AudioSessionController

    var body: some View {
        VStack(spacing: Token.Spacing.s2) {
            switch audio.flow.gate {
            case .askPermission:
                permissionCard
            case .deniedSettings:
                deniedCard
            case .interrupted:
                interruptionBanner
            case .ready:
                if !audio.hasHeadphones {
                    headphoneBanner
                }
            }
        }
    }

    // MARK: - Prompt (notDetermined)

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s2) {
            Label("Microphone access needed", systemImage: "mic.fill")
                .font(Token.Fonts.heading)
            Text("PitchNotes listens locally to show live pitch feedback and grade your takes. Audio is processed on this device only and never leaves your iPhone.")
                .font(Token.Fonts.caption)
                .foregroundStyle(Color.pnTextSecondary)
            Button {
                audio.requestPermission()
            } label: {
                Label("Enable microphone", systemImage: "mic.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
            .accessibilityHint("Opens the system microphone permission dialog")
        }
        .padding(Token.Spacing.s4)
        .background(Color.pnSurfaceElevated, in: RoundedRectangle(cornerRadius: Token.Radius.card))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Denied (Settings deep-link; AC: no crash on deny)

    private var deniedCard: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s2) {
            Label("Microphone access denied", systemImage: "mic.slash.fill")
                .font(Token.Fonts.heading)
                .foregroundStyle(Color.octaveWarn)
            Text("PitchNotes can't listen without microphone access. Open Settings → PitchNotes → Microphone and allow access, then come back.")
                .font(Token.Fonts.caption)
                .foregroundStyle(Color.pnTextSecondary)
            Button {
                audio.openSettings()
            } label: {
                Label("Open Settings", systemImage: "gearshape.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
            .accessibilityHint("Opens the iOS Settings app for PitchNotes")
        }
        .padding(Token.Spacing.s4)
        .background(Color.octaveWarn.opacity(0.10), in: RoundedRectangle(cornerRadius: Token.Radius.card))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Interruption (call / background / foreground)

    private var interruptionBanner: some View {
        HStack(spacing: Token.Spacing.s2) {
            Image(systemName: "phone.down.fill")
                .foregroundStyle(Color.octaveWarn)
            VStack(alignment: .leading, spacing: 2) {
                Text("Audio paused — interrupted by a call or another app.")
                    .font(Token.Fonts.caption)
                    .fontWeight(.semibold)
                Text(audio.flow.shouldResumeAfterInterruption
                     ? "It will resume automatically."
                     : "Resume manually when you're ready.")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
            }
            Spacer()
            if !audio.flow.shouldResumeAfterInterruption {
                Button("Resume") { audio.resumeSession() }
                    .font(Token.Fonts.caption)
                    .buttonStyle(.bordered)
            }
        }
        .padding(Token.Spacing.s3)
        .background(Color.octaveWarn.opacity(0.10), in: RoundedRectangle(cornerRadius: Token.Radius.chip))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Headphone guidance (speaker-mode)

    private var headphoneBanner: some View {
        HStack(spacing: Token.Spacing.s2) {
            Image(systemName: "hifispeaker.2.fill")
                .foregroundStyle(Color.flat)
            Text("No headphones detected — speaker mode can cause echo and pitch errors. Wear headphones for accurate feedback.")
                .font(Token.Fonts.caption)
                .foregroundStyle(Color.pnTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Token.Spacing.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.flat.opacity(0.10), in: RoundedRectangle(cornerRadius: Token.Radius.chip))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Input level meter + latency stub (under the ribbon controls)

struct MicMeterRow: View {
    @ObservedObject var audio: AudioSessionController

    var body: some View {
        HStack(spacing: Token.Spacing.s3) {
            Text("Input level")
                .font(Token.Fonts.caption)
                .foregroundStyle(Color.pnTextSecondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.pnTrack)
                    Capsule()
                        .fill(Color.pnAccent)
                        .frame(width: max(4, geo.size.width * audio.inputLevel))
                        .animation(.easeOut(duration: 0.1), value: audio.inputLevel)
                }
            }
            .frame(height: 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Input level")
            .accessibilityValue("\(Int(audio.inputLevel * 100)) percent")

            Text("\(Int(audio.inputLevel * 100))%")
                .font(Token.Fonts.numeric)
                .foregroundStyle(Color.pnTextSecondary)
                .frame(width: 40, alignment: .trailing)
        }
        .frame(minHeight: 44)
    }
}

struct LatencyStubRow: View {
    /// Persisted locally only (offline app; real calibration J-403/M4).
    @AppStorage("latencyCompensationMs") private var latencyMs = 0

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: Token.Spacing.s1) {
                Slider(value: Binding(
                    get: { Double(latencyMs) },
                    set: { latencyMs = Int($0.rounded()) }
                ), in: 0...300, step: 10)
                .disabled(true) // STUB — wiring lands with P-104/J-403
                .accessibilityLabel("Latency compensation")
                .accessibilityValue("\(latencyMs) milliseconds")
                Text("Stub — \(latencyMs) ms placeholder. Real loopback calibration ships in M4 (J-403): the app plays a click, hears it on the mic, and sets the offset for you.")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
            }
        } label: {
            Label("Latency compensation (M4)", systemImage: "timer")
                .font(Token.Fonts.caption)
                .foregroundStyle(Color.pnTextSecondary)
        }
        .frame(minHeight: 44)
    }
}
