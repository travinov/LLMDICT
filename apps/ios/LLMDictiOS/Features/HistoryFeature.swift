import Observation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct HistoryScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\RecordingItem.createdAt, order: .reverse)]) private var recordings: [RecordingItem]
    @Query(sort: [SortDescriptor(\PromptItem.title)]) private var prompts: [PromptItem]

    @Bindable var controller: AppController
    @State private var importingAudio = false
    @State private var targetForFormatting: RecordingItem?
    @State private var shareItems: [Any] = []
    @State private var showingShareSheet = false
    @State private var pendingDelete: RecordingItem?
    @State private var importErrorMessage = ""
    @State private var showingImportError = false

    var body: some View {
        ZStack {
            AppBackdrop().ignoresSafeArea()

            Group {
                if recordings.isEmpty {
                    emptyState
                } else {
                    listState
                }
            }
        }
        .navigationTitle("История")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    importingAudio = true
                } label: {
                    Label("Импорт", systemImage: "square.and.arrow.down")
                }
            }
        }
        .fileImporter(
            isPresented: $importingAudio,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else {
                    importErrorMessage = "Не удалось получить выбранный аудиофайл."
                    showingImportError = true
                    return
                }
                Task {
                    do {
                        try await controller.importAudioFile(from: url)
                    } catch {
                        importErrorMessage = error.localizedDescription
                        showingImportError = true
                    }
                }
            case let .failure(error):
                importErrorMessage = error.localizedDescription
                showingImportError = true
            }
        }
        .sheet(item: $targetForFormatting) { recording in
            FormattingScenarioSheet(
                prompts: prompts,
                onSelect: { overrideMode in
                    Task { await controller.format(recording, promptOverride: overrideMode) }
                    targetForFormatting = nil
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(items: shareItems)
        }
        .alert("Удалить запись?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if $0 == false { pendingDelete = nil } }
        )) {
            Button("Удалить", role: .destructive) {
                if let pendingDelete {
                    try? controller.delete(pendingDelete)
                }
                self.pendingDelete = nil
            }
            Button("Отмена", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("Файл и локальный транскрипт будут удалены с устройства.")
        }
        .alert("Не удалось импортировать аудио", isPresented: $showingImportError) {
            Button("OK", role: .cancel) {
                importErrorMessage = ""
            }
        } message: {
            Text(importErrorMessage)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            Spacer()
            GlassPanel {
                VStack(spacing: 14) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(Color(red: 0.99, green: 0.79, blue: 0.57))
                    Text("Пока нет записей")
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Сделайте первую запись на главном экране или импортируйте готовый аудиофайл.")
                        .font(.system(.body, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.72))
                    Button("Импортировать аудио") {
                        importingAudio = true
                    }
                    .buttonStyle(PrimaryCapsuleButtonStyle())
                }
            }
            Spacer()
        }
        .padding(20)
    }

    private var listState: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(recordings) { recording in
                    RecordingRow(
                        recording: recording,
                        detailDestination: RecordingDetailScreen(
                            recording: recording,
                            isEnhancing: controller.isEnhancing(recording),
                            enhancementError: controller.enhancementError(for: recording),
                            enhancementReport: controller.enhancementReport(for: recording),
                            useEnhancedAudio: controller.settings.useEnhancedAudio,
                            playingFilePath: controller.player.playingFilePath,
                            onPlayOriginal: { controller.togglePlayback(url: recording.fileURL) },
                            onPlayEnhanced: { controller.togglePlayback(url: recording.enhancedFileURL) },
                            onEnhance: { Task { await controller.enhance(recording) } },
                            onRemoveEnhanced: { controller.removeEnhancedAudio(for: recording) },
                            onShareOriginalAudio: { share(fileURL: recording.fileURL) },
                            onShareEnhancedAudio: { share(fileURL: recording.enhancedFileURL) },
                            onShareRawText: {
                                guard let rawText = recording.rawTextForProcessing else { return }
                                share(text: rawText)
                            },
                            onShareProcessedText: {
                                guard let processedText = recording.processedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines),
                                      processedText.isEmpty == false else { return }
                                share(text: processedText)
                            },
                            onRecognize: { Task { await controller.recognize(recording) } },
                            onFormat: { targetForFormatting = recording }
                        ),
                        isPlaying: controller.player.playingFilePath == controller.audioURL(for: recording).path,
                        isEnhancing: controller.isEnhancing(recording),
                        onPlay: { controller.togglePlayback(for: recording) },
                        onRecognize: { Task { await controller.recognize(recording) } },
                        onFormat: { targetForFormatting = recording },
                        onDelete: { pendingDelete = recording }
                    )
                }
            }
            .padding(20)
        }
        .floatingTabBarClearance()
    }

    private func share(fileURL: URL) {
        shareItems = [fileURL]
        showingShareSheet = true
    }

    private func share(text: String) {
        shareItems = [text]
        showingShareSheet = true
    }
}

private struct RecordingRow<Destination: View>: View {
    let recording: RecordingItem
    let detailDestination: Destination
    let isPlaying: Bool
    let isEnhancing: Bool
    let onPlay: () -> Void
    let onRecognize: () -> Void
    let onFormat: () -> Void
    let onDelete: () -> Void

    var body: some View {
        GlassPanel(cornerRadius: 24) {
            VStack(alignment: .leading, spacing: 14) {
                NavigationLink {
                    detailDestination
                } label: {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(recording.title)
                                    .font(.system(.headline, design: .rounded, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.leading)
                                Text(metaText)
                                    .font(.system(.footnote, design: .rounded, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.64))
                            }
                            Spacer(minLength: 0)
                            statusBadge
                        }

                        if recording.status.isProcessing {
                            ProgressView()
                                .tint(Color(red: 0.99, green: 0.77, blue: 0.53))
                        } else {
                            Text(previewText)
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundStyle(.white.opacity(recording.status == .error || recording.hasTranscript ? 0.82 : 0.62))
                                .lineLimit(4)
                                .multilineTextAlignment(.leading)
                        }

                        HStack {
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white.opacity(0.38))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                HStack(spacing: 10) {
                    actionChip(
                        title: isPlaying ? "Стоп" : "Слушать",
                        icon: isPlaying ? "stop.fill" : "play.fill",
                        action: onPlay
                    )
                    actionChip(
                        title: shouldOfferRecognition ? "Распознать" : "Оформить",
                        icon: shouldOfferRecognition ? "waveform.badge.magnifyingglass" : "text.badge.checkmark",
                        disabled: recording.status.isProcessing || isEnhancing,
                        action: shouldOfferRecognition ? onRecognize : onFormat
                    )
                    actionChip(
                        title: "Удалить",
                        icon: "trash",
                        role: .destructive,
                        disabled: recording.status.isProcessing || isEnhancing,
                        action: onDelete
                    )
                }
            }
        }
    }

    private var metaText: String {
        let dateText = recording.createdAt.formatted(date: .abbreviated, time: .shortened)
        let minutes = Int(recording.duration) / 60
        let seconds = Int(recording.duration) % 60
        let enhanced = recording.hasEnhancedAudio ? " • Улучшено" : ""
        return "\(dateText) • \(String(format: "%02d:%02d", minutes, seconds))\(enhanced)"
    }

    private var previewText: String {
        if recording.status == .error {
            return recording.errorText ?? "Не удалось распознать запись. Повторите попытку."
        }
        return recording.transcriptText
            ?? "Транскрипт ещё не готов. Откройте сценарий распознавания, чтобы получить текст или структурированный результат."
    }

    private var shouldOfferRecognition: Bool {
        guard recording.hasRawTranscript else { return true }
        guard recording.status == .error else { return false }
        let transcriptionError = recording.lastTranscriptionError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let processingError = recording.lastProcessingError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return transcriptionError.isEmpty == false && processingError.isEmpty
    }

    private var statusBadge: some View {
        Text(recording.status.title)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .foregroundStyle(recording.status == .error ? Color(red: 0.4, green: 0.09, blue: 0.09) : .white)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(recording.status == .error ? Color(red: 0.98, green: 0.74, blue: 0.72) : .white.opacity(0.1))
            )
    }

    private func actionChip(
        title: String,
        icon: String,
        role: ButtonRole? = nil,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: icon)
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(
                    (role == .destructive ? Color(red: 1.0, green: 0.84, blue: 0.82) : .white)
                        .opacity(disabled ? 0.38 : 1)
                )
                .lineLimit(1)
                .minimumScaleFactor(0.84)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(
                    .white.opacity(disabled ? 0.04 : (role == .destructive ? 0.08 : 0.11)),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

private struct FormattingScenarioSheet: View {
    let prompts: [PromptItem]
    let onSelect: (PromptOverride) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Быстрый выбор") {
                    Button("Использовать сценарий по умолчанию") {
                        onSelect(.selected)
                    }
                }

                Section("Все сценарии") {
                    ForEach(prompts) { prompt in
                        Button {
                            onSelect(.prompt(prompt))
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(prompt.title)
                                        .foregroundStyle(.primary)
                                    Text(prompt.content)
                                        .lineLimit(2)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if prompt.isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color(red: 0.95, green: 0.41, blue: 0.24))
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Оформление")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct RecordingDetailScreen: View {
    let recording: RecordingItem
    let isEnhancing: Bool
    let enhancementError: String?
    let enhancementReport: AudioEnhancementReport?
    let useEnhancedAudio: Bool
    let playingFilePath: String?
    let onPlayOriginal: () -> Void
    let onPlayEnhanced: () -> Void
    let onEnhance: () -> Void
    let onRemoveEnhanced: () -> Void
    let onShareOriginalAudio: () -> Void
    let onShareEnhancedAudio: () -> Void
    let onShareRawText: () -> Void
    let onShareProcessedText: () -> Void
    let onRecognize: () -> Void
    let onFormat: () -> Void

    var body: some View {
        ZStack {
            AppBackdrop().ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    GlassPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(recording.title)
                                .font(.system(.title3, design: .rounded, weight: .semibold))
                                .foregroundStyle(.white)

                            LabeledContent("Статус", value: recording.status.title)
                                .foregroundStyle(.white.opacity(0.78))
                            LabeledContent("Дата", value: recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.white.opacity(0.78))
                            LabeledContent("Файл", value: recording.fileURL.lastPathComponent)
                                .foregroundStyle(.white.opacity(0.78))
                            LabeledContent(
                                "Версия для работы",
                                value: useEnhancedAudio && recording.hasEnhancedAudio
                                    ? "Обработанная"
                                    : "Оригинал"
                            )
                                .foregroundStyle(.white.opacity(0.78))
                        }
                    }

                    GlassPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Улучшение звука", systemImage: "waveform.badge.plus")
                                .font(.system(.headline, design: .rounded, weight: .semibold))
                                .foregroundStyle(.white)

                            Text("На iPhone: спектральная очистка с выбранной в настройках силой, фильтр низкочастотного гула, компрессор, нормализация до −18 dBFS и безопасный ограничитель пиков −4 dBFS.")
                                .font(.system(.footnote, design: .rounded))
                                .foregroundStyle(.white.opacity(0.68))

                            if isEnhancing {
                                HStack(spacing: 10) {
                                    ProgressView()
                                        .tint(Color(red: 0.99, green: 0.77, blue: 0.53))
                                    Text("Обрабатываем запись…")
                                        .foregroundStyle(.white.opacity(0.82))
                                }
                                .padding(.vertical, 8)
                            } else {
                                actionRow(
                                    title: recording.hasEnhancedAudio ? "Обработать заново" : "Улучшить запись",
                                    icon: "wand.and.stars",
                                    disabled: recording.status.isProcessing,
                                    action: onEnhance
                                )
                            }

                            if recording.hasEnhancedAudio {
                                actionRow(
                                    title: playingFilePath == recording.fileURL.path ? "Остановить оригинал" : "Слушать оригинал",
                                    icon: "waveform",
                                    action: onPlayOriginal
                                )
                                actionRow(
                                    title: playingFilePath == recording.enhancedFileURL.path ? "Остановить улучшенную" : "Слушать улучшенную",
                                    icon: "waveform.badge.checkmark",
                                    action: onPlayEnhanced
                                )
                                actionRow(
                                    title: "Удалить улучшенную версию",
                                    icon: "trash",
                                    disabled: isEnhancing || recording.status.isProcessing,
                                    action: onRemoveEnhanced
                                )
                            }

                            if let enhancementReport {
                                Text(reportText(enhancementReport))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.58))
                            }

                            if let enhancementError, enhancementError.isEmpty == false {
                                Text(enhancementError)
                                    .font(.system(.footnote, design: .rounded))
                                    .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.78))
                            }
                        }
                    }

                    if recording.status == .error {
                        GlassPanel {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(errorTitle, systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(.headline, design: .rounded, weight: .semibold))
                                    .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.78))
                                Text(recording.errorText ?? fallbackErrorText)
                                    .font(.system(.body, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.82))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    GlassPanel {
                        VStack(spacing: 12) {
                            actionRow(
                                title: "Распознать заново",
                                icon: "waveform.badge.magnifyingglass",
                                disabled: recording.status.isProcessing || isEnhancing,
                                action: onRecognize
                            )
                            actionRow(
                                title: "Оформить",
                                icon: "text.badge.checkmark",
                                disabled: recording.status.isProcessing || isEnhancing || !recording.hasRawTranscript,
                                action: onFormat
                            )
                        }
                    }

                    GlassPanel {
                        VStack(spacing: 12) {
                            actionRow(title: "Поделиться оригиналом", icon: "square.and.arrow.up", action: onShareOriginalAudio)
                            if recording.hasEnhancedAudio {
                                actionRow(title: "Поделиться улучшенной версией", icon: "waveform.badge.checkmark", action: onShareEnhancedAudio)
                            }
                            actionRow(
                                title: "Поделиться исходным текстом",
                                icon: "doc.text",
                                disabled: !recording.hasRawTranscript,
                                action: onShareRawText
                            )
                            actionRow(
                                title: "Копировать исходный текст",
                                icon: "document.on.document",
                                disabled: !recording.hasRawTranscript
                            ) {
                                UIPasteboard.general.string = recording.rawTextForProcessing
                            }
                            if let processedText {
                                actionRow(
                                    title: "Поделиться оформленным текстом",
                                    icon: "doc.richtext",
                                    action: onShareProcessedText
                                )
                                actionRow(
                                    title: "Копировать оформленный текст",
                                    icon: "document.on.document.fill"
                                ) {
                                    UIPasteboard.general.string = processedText
                                }
                            }
                        }
                    }

                    if let rawText = recording.rawTextForProcessing {
                        transcriptPanel(title: "Исходный текст", text: rawText)
                    }

                    if let processedText {
                        transcriptPanel(title: "Оформленный текст", text: processedText)
                    }

                    if recording.hasTranscript == false {
                        GlassPanel {
                            Text("Текст пока отсутствует. Запустите распознавание записи.")
                                .font(.system(.body, design: .rounded))
                                .foregroundStyle(.white.opacity(0.64))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Детали")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private var processedText: String? {
        guard let text = recording.processedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.isEmpty == false else {
            return nil
        }
        return text
    }

    private func reportText(_ report: AudioEnhancementReport) -> String {
        String(
            format: "RMS %.1f → %.1f dBFS  •  пик %.1f dBFS  •  усиление %+.1f dB",
            report.inputRMSDecibels,
            report.outputRMSDecibels,
            report.outputPeakDecibels,
            report.normalizationGainDecibels
        )
    }

    private var isProcessingError: Bool {
        recording.lastProcessingError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var errorTitle: String {
        isProcessingError ? "Ошибка оформления" : "Ошибка распознавания"
    }

    private var fallbackErrorText: String {
        isProcessingError
            ? "Не удалось оформить текст. Исходный текст сохранён."
            : "Не удалось распознать запись. Повторите попытку."
    }

    private func transcriptPanel(title: String, text: String) -> some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                Text(text)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private func actionRow(title: String, icon: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
            }
            .font(.system(.body, design: .rounded, weight: .medium))
            .foregroundStyle(disabled ? .white.opacity(0.38) : .white)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }
}
