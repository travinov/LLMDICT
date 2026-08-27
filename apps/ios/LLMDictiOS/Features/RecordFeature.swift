import Observation
import SwiftUI

struct RecordScreen: View {
    @Bindable var controller: AppController

    var body: some View {
        ZStack {
            AppBackdrop().ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    LiveVoiceWaveStrip(
                        level: controller.recorder.micLevel,
                        isRecording: controller.recorder.isRecording
                    )
                    heroSection
                    controlSection
                    hintsSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .floatingTabBarClearance()
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private var heroSection: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center) {
                    GlassOrb(
                        level: controller.recorder.micLevel,
                        timeText: timeString(for: controller.recorder.elapsedTime),
                        isRecording: controller.recorder.isRecording
                    )
                    .frame(maxWidth: .infinity)
                }

                HStack(alignment: .top, spacing: 16) {
                    statusMetric(
                        title: "Режим",
                        value: controller.settings.provider.title,
                        alignment: .leading
                    )

                    statusMetric(
                        title: "Формат",
                        value: "WAV 44.1 kHz",
                        alignment: .trailing
                    )
                }
            }
        }
    }

    private var controlSection: some View {
        GlassPanel {
            VStack(spacing: 18) {
                Text(controller.recorder.statusText)
                    .font(.system(.headline, design: .rounded, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Task {
                        if controller.recorder.isRecording {
                            await controller.stopRecording()
                        } else {
                            await controller.startRecording()
                        }
                    }
                } label: {
                    Label(
                        controller.recorder.isRecording ? "Остановить запись" : "Начать запись",
                        systemImage: controller.recorder.isRecording ? "stop.fill" : "mic.fill"
                    )
                }
                .buttonStyle(PrimaryCapsuleButtonStyle())

                if controller.recorder.isRecording {
                    Button("Отменить и удалить черновик") {
                        controller.recorder.cancelRecording()
                    }
                    .foregroundStyle(.white.opacity(0.76))
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                }
            }
        }
    }

    private var hintsSection: some View {
        VStack(spacing: 14) {
            infoCard(
                icon: "lock.shield",
                title: "Локальное сохранение",
                text: "Каждая запись сразу сохраняется в приватном хранилище приложения и остаётся доступной в истории."
            )
            infoCard(
                icon: "sparkles.rectangle.stack",
                title: "Распознавание и оформление",
                text: "В истории сначала получите исходный текст, а затем при необходимости оформите его выбранным сценарием. Повторное оформление не загружает аудио заново."
            )
        }
    }

    private func statusMetric(title: String, value: String, alignment: Alignment) -> some View {
        VStack(alignment: alignment == .leading ? .leading : .trailing, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.58))
            Text(value)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    private func infoCard(icon: String, title: String, text: String) -> some View {
        GlassPanel(cornerRadius: 24) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color(red: 0.98, green: 0.78, blue: 0.56))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(text)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func timeString(for interval: TimeInterval) -> String {
        let duration = max(0, Int(interval.rounded()))
        let seconds = duration % 60
        let minutes = (duration / 60) % 60
        let hours = duration / 3600
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
