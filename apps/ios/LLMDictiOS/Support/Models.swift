import Foundation
import SwiftData

enum RecordingStatus: String, CaseIterable, Codable {
    case localOnly = "local_only"
    case imported
    case transcribing
    case transcribingOpenAI = "transcribing_openai"
    case transcribingGigachat = "transcribing_gigachat"
    case processingText = "processing_text"
    case transcribed
    case error

    var title: String {
        switch self {
        case .localOnly:
            return "Локально"
        case .imported:
            return "Импортировано"
        case .transcribing:
            return "Распознавание"
        case .transcribingOpenAI:
            return "Обработка OpenAI"
        case .transcribingGigachat:
            return "Обработка GigaChat"
        case .processingText:
            return "Оформление"
        case .transcribed:
            return "Готово"
        case .error:
            return "Ошибка"
        }
    }

    var isProcessing: Bool {
        switch self {
        case .transcribing, .transcribingOpenAI, .transcribingGigachat, .processingText:
            return true
        default:
            return false
        }
    }
}

enum TranscriptionProvider: String, CaseIterable, Codable, Identifiable {
    case openAITranscribe
    case openAITranscribeMini
    case openAIWhisper
    case openAIRealtimeWhisper
    case openAIGPT4o
    case sberSalute

    static let productionCases: [TranscriptionProvider] = [
        .openAITranscribe,
        .openAITranscribeMini,
        .sberSalute
    ]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAITranscribe, .openAIWhisper, .openAIRealtimeWhisper, .openAIGPT4o:
            return "gpt-4o-transcribe"
        case .openAITranscribeMini:
            return "gpt-4o-mini-transcribe"
        case .sberSalute:
            return "SaluteSpeech"
        }
    }

    var normalized: TranscriptionProvider {
        switch self {
        case .openAIWhisper, .openAIRealtimeWhisper, .openAIGPT4o:
            return .openAITranscribe
        case .openAITranscribe, .openAITranscribeMini, .sberSalute:
            return self
        }
    }
}

enum ProcessingModelProfile: String, CaseIterable, Codable, Identifiable {
    case gpt56Luna
    case gpt56Terra

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gpt56Luna:
            return "GPT-5.6 Luna"
        case .gpt56Terra:
            return "GPT-5.6 Terra"
        }
    }

    var modelID: String {
        switch self {
        case .gpt56Luna:
            return "gpt-5.6-luna"
        case .gpt56Terra:
            return "gpt-5.6-terra"
        }
    }
}

@Model
final class RecordingItem {
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var duration: TimeInterval
    var filePath: String
    var statusRaw: String
    var transcriptPreview: String
    var rawTranscript: String?
    var processedTranscript: String?
    var lastTranscriptionError: String?
    var lastProcessingError: String?

    init(
        title: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        duration: TimeInterval = 0,
        filePath: String,
        status: RecordingStatus = .localOnly,
        transcriptPreview: String = "",
        rawTranscript: String? = nil,
        processedTranscript: String? = nil,
        lastTranscriptionError: String? = nil,
        lastProcessingError: String? = nil
    ) {
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.duration = duration
        self.filePath = filePath
        self.statusRaw = status.rawValue
        self.transcriptPreview = transcriptPreview
        self.rawTranscript = rawTranscript
        self.processedTranscript = processedTranscript
        self.lastTranscriptionError = lastTranscriptionError
        self.lastProcessingError = lastProcessingError
    }

    var status: RecordingStatus {
        get { RecordingStatus(rawValue: statusRaw) ?? .localOnly }
        set { statusRaw = newValue.rawValue }
    }

    var fileURL: URL {
        let storedURL = URL(fileURLWithPath: filePath)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: storedURL.path) {
            return storedURL
        }

        // The UUID of an iOS data container can change after reinstall/update.
        // Absolute paths persisted by older builds must therefore be rebased into
        // the current sandbox while preserving the recording filename.
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return storedURL
        }
        let rebasedURL = applicationSupport
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent(storedURL.lastPathComponent, isDirectory: false)
        return fileManager.fileExists(atPath: rebasedURL.path) ? rebasedURL : storedURL
    }

    var enhancedFileURL: URL {
        let fileManager = FileManager.default
        let storedURL = URL(fileURLWithPath: filePath)
        let storedEnhancedURL = storedURL
            .deletingPathExtension()
            .appendingPathExtension("enhanced.wav")

        // Imported or test recordings can legitimately live outside the app's
        // Recordings directory. Keep their sidecar next to the existing source
        // instead of rebasing it into Application Support.
        if fileManager.fileExists(atPath: storedURL.path) {
            return storedEnhancedURL
        }

        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return storedEnhancedURL
        }

        let rebasedDirectory = applicationSupport
            .appendingPathComponent("Recordings", isDirectory: true)
        let rebasedURL = rebasedDirectory
            .appendingPathComponent(storedURL.deletingPathExtension().lastPathComponent, isDirectory: false)
            .deletingPathExtension()
            .appendingPathExtension("enhanced.wav")

        return rebasedURL
    }

    var hasEnhancedAudio: Bool {
        FileManager.default.fileExists(atPath: enhancedFileURL.path)
    }

    var preferredAudioURL: URL {
        hasEnhancedAudio ? enhancedFileURL : fileURL
    }

    var transcriptText: String? {
        nonEmpty(processedTranscript) ?? rawTextForProcessing
    }

    var hasTranscript: Bool {
        transcriptText != nil
    }

    var hasRawTranscript: Bool {
        rawTextForProcessing != nil
    }

    var rawTextForProcessing: String? {
        if let raw = nonEmpty(rawTranscript) {
            return raw
        }
        guard status != .error || nonEmpty(lastProcessingError) != nil else { return nil }
        return nonEmpty(transcriptPreview)
    }

    var errorText: String? {
        nonEmpty(lastProcessingError)
            ?? nonEmpty(lastTranscriptionError)
            ?? (status == .error ? nonEmpty(transcriptPreview) : nil)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}

@Model
final class PromptItem {
    var title: String
    var content: String
    var isSelected: Bool

    init(title: String, content: String, isSelected: Bool = false) {
        self.title = title
        self.content = content
        self.isSelected = isSelected
    }
}

struct DefaultPrompt: Sendable {
    let title: String
    let content: String

    static let presets: [DefaultPrompt] = [
        DefaultPrompt(
            title: "Протокол встречи",
            content: """
            {system} Ты профессиональный секретарь. Твоя задача — составить официальный протокол встречи.
            Структура:
            1. Темы: О чем говорили.
            2. Решения: Что утвердили.
            3. Задачи: Список «Задача — Ответственный — Срок».
            4. Детали: Важные цифры и факты.
            Стиль: Деловой, без воды.
            {user} Составь протокол этой встречи.
            """
        ),
        DefaultPrompt(
            title: "Конспект лекции",
            content: """
            {system} Ты прилежный студент. Составь конспект лекции.
            1. Структурируй материал.
            2. Выпиши определения терминов.
            3. Кратко опиши примеры.
            4. В конце дай 3 ключевых вывода.
            {user} Сделай подробный конспект.
            """
        ),
        DefaultPrompt(
            title: "Редактор (Письмо/Пост)",
            content: """
            {system} Ты редактор и корректор. Преврати устную речь в идеальный письменный текст.
            1. Исправь ошибки и стиль.
            2. Убери повторы и слова-паразиты.
            3. Разбей на абзацы.
            4. Сохрани смысл и интонацию.
            {user} Преврати эту диктовку в чистовой текст.
            """
        ),
        DefaultPrompt(
            title: "Генерация идей",
            content: """
            {system} Ты аналитик. Я наговариваю поток идей.
            1. Выдели каждую идею отдельным пунктом.
            2. Дай ей название.
            3. Опиши суть в одном предложении.
            4. Укажи плюсы и минусы, если они упомянуты.
            {user} Структурируй мои идеи.
            """
        ),
        DefaultPrompt(
            title: "Дневник / Рефлексия",
            content: """
            {system} Ты чуткий психолог. Проанализируй мою запись.
            1. Опиши события и эмоции.
            2. Предложи вопросы для размышления.
            3. Поддержи меня.
            {user} Это запись в дневник. Проанализируй её.
            """
        ),
        DefaultPrompt(
            title: "Умный список покупок",
            content: """
            {system} Я диктую список покупок. Твоя задача:
            1. Выделить товары.
            2. Сгруппировать их по категориям.
            3. Если указано количество — добавить.
            4. Вывести в виде удобного чеклиста.
            {user} Составь список покупок по категориям.
            """
        )
    ]
}
