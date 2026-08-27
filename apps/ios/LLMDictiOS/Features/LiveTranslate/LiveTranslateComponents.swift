import SwiftUI

struct LivePushToTalkButton: View {
    let speaker: LiveTranslateSpeaker
    let state: LiveTranslateButtonState
    let routeText: String
    let level: Double
    let actionColor: Color
    let onPress: () -> Void
    let onRelease: () -> Void

    @State private var isPressed = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)

            Text(speaker.buttonTitle)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.82)

            Text(routeText)
                .font(.system(.caption2, design: .rounded, weight: .bold))
                .foregroundStyle(.white.opacity(0.58))
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(state.title)
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.82)

            LiveMiniLevelWave(level: level, isActive: state == .recording)
                .frame(height: 28)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, minHeight: 142)
        .padding(14)
        .background(background, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(.white.opacity(state == .recording ? 0.28 : 0.1), lineWidth: 1)
        }
        .scaleEffect(isPressed && isEnabled ? 0.985 : 1)
        .opacity(isEnabled ? 1 : 0.52)
        .animation(.easeInOut(duration: 0.16), value: state)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard isEnabled, isPressed == false else { return }
                    isPressed = true
                    onPress()
                }
                .onEnded { _ in
                    guard isPressed else { return }
                    isPressed = false
                    onRelease()
                }
        )
        .accessibilityLabel(speaker.buttonTitle)
    }

    private var isEnabled: Bool {
        switch state {
        case .ready, .recording, .error:
            return true
        case .processing, .speaking, .locked:
            return false
        }
    }

    private var iconName: String {
        switch state {
        case .recording:
            return "waveform"
        case .processing:
            return "arrow.triangle.2.circlepath"
        case .speaking:
            return "speaker.wave.2.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        default:
            return speaker == .owner ? "person.wave.2.fill" : "person.2.wave.2.fill"
        }
    }

    private var background: LinearGradient {
        let strength = state == .recording ? 0.36 + (level * 0.28) : 0.18
        return LinearGradient(
            colors: [
                actionColor.opacity(strength + 0.18),
                .white.opacity(0.07)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct LiveMiniLevelWave: View {
    let level: Double
    let isActive: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<18, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(.white.opacity(isActive ? 0.82 : 0.24))
                    .frame(width: 4, height: height(for: index))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func height(for index: Int) -> CGFloat {
        guard isActive else { return 6 }
        let phase = abs(sin(Double(index) * 0.52))
        return 7 + CGFloat(max(0.04, level) * (16 + phase * 18))
    }
}

struct LiveDialogueTurnRow: View {
    let turn: LiveTranslateTurn
    let onReplay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(turn.speaker.title)
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(.white.opacity(0.84))
                Spacer()
                Text("\(turn.sourceLanguage) -> \(turn.targetLanguage)")
                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.54))
                if turn.audioFilePath != nil {
                    Button {
                        onReplay()
                    } label: {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Повторить перевод")
                }
            }

            Text(turn.translatedText)
                .font(.system(.body, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .textSelection(.enabled)

            Text(turn.originalText)
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
