import SwiftUI
import UIKit

struct LiveTranscribeScreen: View {
    @State private var viewModel: LiveTranscribeViewModel

    init(controller: AppController) {
        _viewModel = State(initialValue: LiveTranscribeViewModel(settings: controller.settings))
    }

    var body: some View {
        ZStack {
            AppBackdrop().ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    statusPanel
                    controlsPanel
                    transcriptPanel
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .floatingTabBarClearance()
        }
        .navigationTitle("Live Transcribe")
        .navigationBarTitleDisplayMode(.large)
        .alert("Live Transcribe", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onDisappear {
            guard viewModel.state.isActive else { return }
            Task { await viewModel.cancel() }
        }
    }

    private var statusPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: viewModel.state == .recording ? "captions.bubble.fill" : "captions.bubble")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(viewModel.state.title)
                            .font(.headline)
                        Text("gpt-realtime-whisper · PCM 24 кГц")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Circle()
                        .fill(viewModel.state == .recording ? Color.red : Color.white.opacity(0.25))
                        .frame(width: 11, height: 11)
                        .shadow(color: viewModel.state == .recording ? .red.opacity(0.6) : .clear, radius: 6)
                }

                LiveVoiceWaveStrip(level: viewModel.micLevel, isRecording: viewModel.state == .recording)
            }
        }
    }

    private var controlsPanel: some View {
        GlassPanel {
            VStack(spacing: 14) {
                HStack {
                    Text("Язык речи")
                    Spacer()
                    Picker("Язык речи", selection: $viewModel.settings.liveTranscribeLanguageCode) {
                        ForEach(LiveTranslateLanguage.supported) { language in
                            Text(language.title).tag(language.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(viewModel.state.isActive)
                    .accessibilityIdentifier("liveTranscribe.language")
                }

                Divider().overlay(.white.opacity(0.12))

                HStack {
                    Text("Задержка")
                    Spacer()
                    Picker("Задержка", selection: $viewModel.settings.liveTranscribeDelay) {
                        ForEach(LiveTranscriptionDelay.allCases) { delay in
                            Text(delay.title).tag(delay)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(viewModel.state.isActive)
                    .accessibilityIdentifier("liveTranscribe.delay")
                }

                Button {
                    Task {
                        if viewModel.state.isActive {
                            await viewModel.stop()
                        } else {
                            await viewModel.start()
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: viewModel.state.isActive ? "stop.fill" : "mic.fill")
                        Text(viewModel.state.isActive ? "Остановить" : "Начать распознавание")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.state.isActive ? .red : .orange)
                .disabled(viewModel.state == .connecting || viewModel.state == .finishing)
                .accessibilityIdentifier("liveTranscribe.toggle")

                Text("Для публичной версии приложения используйте ephemeral endpoint, чтобы API key не хранился на устройстве.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var transcriptPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Текст")
                        .font(.headline)
                    Spacer()

                    Button {
                        UIPasteboard.general.string = viewModel.displayedTranscript
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(viewModel.displayedTranscript.isEmpty)
                    .accessibilityLabel("Копировать текст")

                    ShareLink(item: viewModel.displayedTranscript) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(viewModel.displayedTranscript.isEmpty)

                    Button(role: .destructive) {
                        viewModel.clear()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(viewModel.displayedTranscript.isEmpty || viewModel.state.isActive)
                    .accessibilityLabel("Очистить текст")
                }

                if viewModel.displayedTranscript.isEmpty {
                    ContentUnavailableView(
                        "Текст появится здесь",
                        systemImage: "waveform.and.mic",
                        description: Text("Нажмите «Начать распознавание» и говорите как обычно.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 210)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(viewModel.finalTranscript)
                            .foregroundStyle(.primary)
                        if viewModel.partialTranscript.isEmpty == false {
                            Text(viewModel.finalTranscript.isEmpty ? viewModel.partialTranscript : " \(viewModel.partialTranscript)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
                    .accessibilityIdentifier("liveTranscribe.transcript")
                }
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if $0 == false { viewModel.errorMessage = nil } }
        )
    }
}
