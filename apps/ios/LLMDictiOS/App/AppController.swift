import AVFoundation
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class AppController {
    var settings: AppSettings
    var recorder: AudioRecorderService
    var player: AudioPlayerService
    var companion: RecorderCompanionService
    private(set) var enhancingFilePaths: Set<String> = []
    private(set) var enhancementErrors: [String: String] = [:]
    private(set) var enhancementReports: [String: AudioEnhancementReport] = [:]

    private let modelContext: ModelContext
    private let transcriber: any TranscriptionServicing
    private let textProcessor: any TextProcessingServicing
    private let audioEnhancer: AudioEnhancementService

    init(
        modelContext: ModelContext,
        transcriber: any TranscriptionServicing = TranscriptionService(),
        textProcessor: any TextProcessingServicing = TextProcessingService(),
        companion: RecorderCompanionService = RecorderCompanionService(),
        audioEnhancer: AudioEnhancementService = AudioEnhancementService()
    ) {
        self.modelContext = modelContext
        self.settings = AppSettings()
        self.recorder = AudioRecorderService()
        self.player = AudioPlayerService()
        self.companion = companion
        self.transcriber = transcriber
        self.textProcessor = textProcessor
        self.audioEnhancer = audioEnhancer
    }

    func seedPromptsIfNeeded() throws {
        let promptCount = try modelContext.fetchCount(FetchDescriptor<PromptItem>())
        guard promptCount == 0 else { return }

        for (index, item) in DefaultPrompt.presets.enumerated() {
            modelContext.insert(PromptItem(title: item.title, content: item.content, isSelected: index == 0))
        }
        try persist()
    }

    func startRecording() async {
        do {
            try await recorder.startRecording(audioEnhancement: settings.audioEnhancementEnabled)
        } catch {
            recorder.setStatus(error.localizedDescription)
        }
    }

    func stopRecording() async {
        do {
            let clip = try recorder.stopRecording()
            let recording = try createRecording(from: clip)
            await enhance(recording)
        } catch {
            recorder.setStatus(error.localizedDescription)
        }
    }

    func importAudioFile(from originalURL: URL) async throws {
        let destinationDirectory = try recordingsDirectory()
        let sanitizedName = originalURL.lastPathComponent.replacingOccurrences(of: " ", with: "_")
        let destinationURL = destinationDirectory.appendingPathComponent("\(UUID().uuidString)_\(sanitizedName)")

        if originalURL.startAccessingSecurityScopedResource() {
            defer { originalURL.stopAccessingSecurityScopedResource() }
            try FileManager.default.copyItem(at: originalURL, to: destinationURL)
        } else {
            try FileManager.default.copyItem(at: originalURL, to: destinationURL)
        }

        let duration = try await audioDuration(for: destinationURL)
        let item = RecordingItem(
            title: originalURL.deletingPathExtension().lastPathComponent,
            duration: duration,
            filePath: destinationURL.path,
            status: .imported
        )
        modelContext.insert(item)
        try persist()
        await enhance(item)
    }

    func syncLatestCompanionRecording() async {
        do {
            let temporaryURL = try await companion.downloadLatestRecording()
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            try await importAudioFile(from: temporaryURL)
            companion.markImported()
        } catch {
            companion.report(error)
        }
    }

    func delete(_ recording: RecordingItem) throws {
        guard isEnhancing(recording) == false else {
            throw RecordingOperationError.cannotDeleteWhileEnhancing
        }
        guard recording.status.isProcessing == false else {
            throw RecordingOperationError.cannotDeleteWhileProcessing
        }

        if player.playingFilePath == recording.filePath || player.playingFilePath == recording.enhancedFileURL.path {
            player.stop()
        }

        try? FileManager.default.removeItem(at: recording.fileURL)
        try? FileManager.default.removeItem(at: recording.enhancedFileURL)
        modelContext.delete(recording)
        try persist()
    }

    func togglePlayback(for recording: RecordingItem) {
        togglePlayback(url: audioURL(for: recording))
    }

    func audioURL(for recording: RecordingItem) -> URL {
        settings.useEnhancedAudio && recording.hasEnhancedAudio
            ? recording.enhancedFileURL
            : recording.fileURL
    }

    func togglePlayback(url: URL) {
        do {
            try player.togglePlayback(url: url)
        } catch {
            player.stop()
        }
    }

    func isEnhancing(_ recording: RecordingItem) -> Bool {
        enhancingFilePaths.contains(recording.filePath)
    }

    func enhancementError(for recording: RecordingItem) -> String? {
        enhancementErrors[recording.filePath]
    }

    func enhancementReport(for recording: RecordingItem) -> AudioEnhancementReport? {
        enhancementReports[recording.filePath]
    }

    func enhance(_ recording: RecordingItem) async {
        guard isEnhancing(recording) == false else { return }
        guard recording.status.isProcessing == false else { return }

        let key = recording.filePath
        enhancingFilePaths.insert(key)
        enhancementErrors[key] = nil
        enhancementReports[key] = nil

        if player.playingFilePath == recording.filePath || player.playingFilePath == recording.enhancedFileURL.path {
            player.stop()
        }

        do {
            let report = try await audioEnhancer.enhance(
                sourceURL: recording.fileURL,
                destinationURL: recording.enhancedFileURL,
                denoiseStrength: settings.audioDenoiseStrength
            )
            enhancementReports[key] = report
            recording.updatedAt = .now
            try persist()
        } catch is CancellationError {
            enhancementErrors[key] = "Обработка отменена. Исходная запись сохранена."
        } catch {
            enhancementErrors[key] = error.localizedDescription
        }

        enhancingFilePaths.remove(key)
    }

    func removeEnhancedAudio(for recording: RecordingItem) {
        guard recording.status.isProcessing == false else { return }
        if player.playingFilePath == recording.enhancedFileURL.path {
            player.stop()
        }
        try? FileManager.default.removeItem(at: recording.enhancedFileURL)
        enhancementReports[recording.filePath] = nil
        enhancementErrors[recording.filePath] = nil
        recording.updatedAt = .now
        try? persist()
    }

    func recognize(_ recording: RecordingItem) async {
        guard recording.status.isProcessing == false else { return }

        let previousTranscriptPreview = recording.transcriptPreview
        let previousRawTranscript = recording.rawTranscript
        let previousProcessedTranscript = recording.processedTranscript

        do {
            recording.lastTranscriptionError = nil
            recording.lastProcessingError = nil
            recording.updatedAt = .now
            recording.status = .transcribing
            try persist()

            let snapshot = SettingsSnapshot(settings: settings)
            let text = try await transcriber.transcribe(
                recordingURL: audioURL(for: recording),
                settings: snapshot
            )

            recording.updatedAt = .now
            recording.status = .transcribed
            recording.rawTranscript = text
            recording.processedTranscript = nil
            recording.transcriptPreview = text
            recording.lastTranscriptionError = nil
            recording.lastProcessingError = nil
            try persist()
        } catch {
            recording.transcriptPreview = previousTranscriptPreview
            recording.rawTranscript = previousRawTranscript
            recording.processedTranscript = previousProcessedTranscript
            recording.updatedAt = .now
            recording.status = .error
            recording.lastTranscriptionError = error.localizedDescription
            recording.lastProcessingError = nil
            try? persist()
        }
    }

    func format(_ recording: RecordingItem, promptOverride: PromptOverride) async {
        guard recording.status.isProcessing == false else { return }

        guard let rawTranscript = recording.rawTextForProcessing else {
            recordFormattingFailure(RecordingOperationError.missingRawTranscript, for: recording)
            return
        }

        do {
            guard let prompt = try resolvePrompt(for: promptOverride)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  prompt.isEmpty == false else {
                throw RecordingOperationError.missingFormattingPrompt
            }

            let previousProcessedTranscript = recording.processedTranscript
            recording.lastProcessingError = nil
            recording.updatedAt = .now
            recording.status = .processingText
            try persist()

            do {
                let text = try await textProcessor.process(
                    rawTranscript: rawTranscript,
                    prompt: prompt,
                    settings: SettingsSnapshot(settings: settings)
                )
                recording.processedTranscript = text
                recording.updatedAt = .now
                recording.status = .transcribed
                recording.lastProcessingError = nil
                try persist()
            } catch {
                recording.processedTranscript = previousProcessedTranscript
                throw error
            }
        } catch {
            recordFormattingFailure(error, for: recording)
        }
    }

    func recoverInterruptedOperations() throws {
        let recordings = try modelContext.fetch(FetchDescriptor<RecordingItem>())
        let interruptedRecordings = recordings.filter { $0.status.isProcessing }
        guard interruptedRecordings.isEmpty == false else { return }

        for recording in interruptedRecordings {
            let wasFormatting = recording.status == .processingText
            recording.status = .error
            if wasFormatting {
                recording.lastProcessingError = "Оформление было прервано при предыдущем запуске. Запустите его повторно."
            } else {
                recording.lastProcessingError = nil
                recording.lastTranscriptionError = "Распознавание было прервано при предыдущем запуске. Запустите его повторно."
            }
        }
        try persist()
    }

    func repairRecordingFilePaths() throws {
        let recordings = try modelContext.fetch(FetchDescriptor<RecordingItem>())
        var changed = false

        for recording in recordings {
            let resolvedPath = recording.fileURL.path
            guard resolvedPath != recording.filePath else { continue }
            recording.filePath = resolvedPath
            changed = true
        }

        if changed {
            try persist()
        }
    }

    func setSelectedPrompt(_ prompt: PromptItem?) throws {
        let prompts = try modelContext.fetch(FetchDescriptor<PromptItem>())
        for item in prompts {
            item.isSelected = item.persistentModelID == prompt?.persistentModelID
        }
        try persist()
    }

    func savePrompt(editing prompt: PromptItem?, title: String, content: String) throws {
        if let prompt {
            prompt.title = title
            prompt.content = content
        } else {
            modelContext.insert(PromptItem(title: title, content: content))
        }
        try persist()
    }

    func deletePrompt(_ prompt: PromptItem) throws {
        let wasSelected = prompt.isSelected
        modelContext.delete(prompt)
        if wasSelected {
            let descriptor = FetchDescriptor<PromptItem>(sortBy: [SortDescriptor(\.title)])
            if let fallback = try modelContext.fetch(descriptor).first {
                fallback.isSelected = true
            }
        }
        try persist()
    }

    func selectedPrompt() throws -> PromptItem? {
        let descriptor = FetchDescriptor<PromptItem>(
            predicate: #Predicate { $0.isSelected == true }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func createRecording(from clip: RecordedClip) throws -> RecordingItem {
        let date = Date()
        let item = RecordingItem(
            title: "Запись \(DateFormatter.recordingTitle.string(from: date))",
            createdAt: date,
            updatedAt: date,
            duration: clip.duration,
            filePath: clip.url.path,
            status: .localOnly
        )
        modelContext.insert(item)
        try persist()
        return item
    }

    private func resolvePrompt(for override: PromptOverride) throws -> String? {
        switch override {
        case .none:
            return nil
        case .selected:
            return try selectedPrompt()?.content
        case let .prompt(prompt):
            return prompt.content
        }
    }

    private func recordFormattingFailure(_ error: Error, for recording: RecordingItem) {
        recording.updatedAt = .now
        recording.status = .error
        recording.lastProcessingError = error.localizedDescription
        try? persist()
    }

    private func recordingsDirectory() throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func audioDuration(for url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return duration.seconds.isFinite ? duration.seconds : 0
    }

    private func persist() throws {
        try modelContext.save()
    }

}

enum RecordingOperationError: LocalizedError {
    case cannotDeleteWhileEnhancing
    case cannotDeleteWhileProcessing
    case missingRawTranscript
    case missingFormattingPrompt

    var errorDescription: String? {
        switch self {
        case .cannotDeleteWhileEnhancing:
            return "Нельзя удалить запись во время улучшения звука. Дождитесь завершения."
        case .cannotDeleteWhileProcessing:
            return "Нельзя удалить запись, пока выполняется операция. Дождитесь её завершения."
        case .missingRawTranscript:
            return "Сначала распознайте запись, чтобы получить исходный текст."
        case .missingFormattingPrompt:
            return "Выберите непустой сценарий оформления."
        }
    }
}

enum PromptOverride {
    case selected
    case none
    case prompt(PromptItem)
}

private extension DateFormatter {
    static let recordingTitle: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()
}
