import SwiftUI

struct AppBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.08, blue: 0.16),
                    Color(red: 0.08, green: 0.16, blue: 0.29),
                    Color(red: 0.83, green: 0.47, blue: 0.22)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.white.opacity(0.12))
                .blur(radius: 80)
                .frame(width: 280, height: 280)
                .offset(x: 120, y: -220)

            Circle()
                .fill(Color(red: 0.99, green: 0.74, blue: 0.55).opacity(0.16))
                .blur(radius: 90)
                .frame(width: 260, height: 260)
                .offset(x: -140, y: 260)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct GlassPanel<Content: View>: View {
    let cornerRadius: CGFloat
    @ViewBuilder var content: Content

    init(cornerRadius: CGFloat = 28, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26, *) {
            content
                .padding(20)
                .background(Color.clear)
                .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
                .padding(20)
                .background(.ultraThinMaterial.opacity(0.92), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                }
        }
    }
}

extension View {
    func floatingTabBarClearance(_ height: CGFloat = 118) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear
                .frame(height: height)
                .allowsHitTesting(false)
        }
    }
}

struct LiveVoiceWaveStrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let level: Double
    let isRecording: Bool

    @State private var samples = Array(repeating: 0.02, count: 44)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(isRecording ? "LIVE VOICE" : "MIC READY")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(2.8)
                    .foregroundStyle(.white.opacity(0.7))

                Spacer()

                Text(signalLabel)
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(signalColor.opacity(0.92))
            }

            HStack(alignment: .center, spacing: 3) {
                ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                    Capsule(style: .continuous)
                        .fill(barGradient(sample: sample, index: index))
                        .frame(width: 4, height: barHeight(sample: sample, index: index))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 62, maxHeight: 62, alignment: .center)
            .animation(.easeInOut(duration: reduceMotion ? 0.2 : 0.12), value: samples)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
        .onAppear {
            samples = Array(repeating: effectiveLevel, count: 44)
        }
        .onChange(of: level) { _, newValue in
            pushSample(effectiveLevel(for: newValue))
        }
        .onChange(of: isRecording) { _, newValue in
            if newValue == false {
                samples = Array(repeating: 0.02, count: 44)
            }
        }
    }

    private var effectiveLevel: Double {
        effectiveLevel(for: level)
    }

    private var signalColor: Color {
        if isRecording == false {
            return .white.opacity(0.8)
        }

        return Color(
            hue: 0.05,
            saturation: 0.12 + (effectiveLevel * 0.7),
            brightness: 1
        )
    }

    private var signalLabel: String {
        guard isRecording else { return "Ожидание" }
        switch effectiveLevel {
        case ..<0.08:
            return "Тихо"
        case ..<0.2:
            return "Слабо"
        case ..<0.48:
            return "Нормально"
        default:
            return "Чётко"
        }
    }

    private func barHeight(sample: Double, index: Int) -> CGFloat {
        let floorLevel = isRecording ? 0.02 : 0.04
        let clamped = max(sample, floorLevel)
        let envelope = 0.74 + (0.26 * sin(Double(index) * 0.28))
        return 10 + CGFloat(clamped * 40 * envelope)
    }

    private func barGradient(sample: Double, index: Int) -> LinearGradient {
        let emphasis = 0.2 + (sample * 0.8)
        return LinearGradient(
            colors: [
                .white.opacity(0.42 + (emphasis * 0.42)),
                signalColor.opacity(0.34 + (emphasis * 0.58))
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func pushSample(_ sample: Double) {
        let normalized = max(0.02, min(1, sample))
        guard samples.isEmpty == false else {
            samples = [normalized]
            return
        }

        samples.insert(normalized, at: 0)
        if samples.count > 44 {
            samples.removeLast(samples.count - 44)
        }
    }

    private func effectiveLevel(for rawLevel: Double) -> Double {
        guard isRecording else { return 0.02 }
        let boosted = pow(max(0, min(1, rawLevel)), 0.82) * 1.18
        return max(0.02, min(1, boosted))
    }
}

struct GlassOrb: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let level: Double
    let timeText: String
    let isRecording: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 0.2 : (1 / 24))) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            let displayLevel = isRecording ? level : 0
            let primaryColor = signalPrimaryColor(for: displayLevel)
            let ringColor = signalRingColor(for: displayLevel)

            ZStack {
                if isRecording {
                    ForEach(0..<3, id: \.self) { index in
                        OrbPulseRing(level: displayLevel, phase: phase, index: index, color: ringColor)
                    }
                }

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                primaryColor.opacity(isRecording ? (0.2 + displayLevel * 0.72) : 0.32),
                                primaryColor.opacity(isRecording ? (0.1 + displayLevel * 0.34) : 0.16),
                                .clear
                            ],
                            center: .center,
                            startRadius: 10,
                            endRadius: 140
                        )
                    )
                    .blur(radius: 18)
                    .scaleEffect(coreGlowScale)
                    .animation(.easeInOut(duration: 0.16), value: level)

                Circle()
                    .strokeBorder(ringColor.opacity(isRecording ? 0.46 : 0.22), lineWidth: 1)
                    .background {
                        Circle()
                            .fill(primaryColor.opacity(isRecording ? (0.05 + displayLevel * 0.12) : 0.05))
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        ringColor.opacity(isRecording ? 0.7 : 0.38),
                                        .white.opacity(0.08)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    }
                    .frame(width: 228, height: 228)
                    .blur(radius: 0.2)

                VStack(spacing: 8) {
                    Text(isRecording ? "LIVE" : "READY")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .tracking(3)
                        .foregroundStyle(ringColor.opacity(0.86))
                    Text(timeText)
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                .padding(.top, 8)
            }
        }
        .frame(width: 260, height: 260)
    }

    private var coreGlowScale: CGFloat {
        let pulse = isRecording ? max(level, 0.01) : 0.04
        return 1 + CGFloat(pulse * (reduceMotion ? 0.06 : 0.2))
    }

    private func signalPrimaryColor(for level: Double) -> Color {
        if isRecording == false {
            return Color(red: 0.99, green: 0.58, blue: 0.46)
        }

        let saturation = 0.16 + (level * 0.74)
        return Color(hue: 0.03, saturation: saturation, brightness: 1)
    }

    private func signalRingColor(for level: Double) -> Color {
        let whiteness = max(0.18, 0.76 - (level * 0.52))
        return Color(
            red: 1,
            green: 0.9 - (level * 0.14),
            blue: 0.82 - (level * 0.22)
        ).opacity(1 - whiteness * 0.18)
    }
}

private struct OrbPulseRing: View {
    let level: Double
    let phase: TimeInterval
    let index: Int
    let color: Color

    var body: some View {
        let progress = ringProgress
        let ringLevel = max(level, 0.02)

        Circle()
            .stroke(color.opacity((1 - progress) * (0.05 + ringLevel * 0.34)), lineWidth: 1.2 + (ringLevel * 0.5))
            .frame(width: 204, height: 204)
            .scaleEffect(1 + (progress * (0.08 + ringLevel * 0.42)))
            .blur(radius: progress * 0.6)
    }

    private var ringProgress: Double {
        let speed = 0.72
        let shifted = (phase * speed) + (Double(index) * 0.24)
        return shifted - floor(shifted)
    }
}

struct PrimaryCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.97, green: 0.49, blue: 0.26),
                                Color(red: 0.95, green: 0.31, blue: 0.22)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .shadow(color: Color.black.opacity(0.18), radius: 18, y: 10)
    }
}
