import Foundation

enum LiveTranslateSpeaker: String, Codable, CaseIterable, Identifiable, Sendable {
    case owner
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .owner:
            return "Я"
        case .other:
            return "Собеседник"
        }
    }

    var buttonTitle: String {
        switch self {
        case .owner:
            return "Я говорю"
        case .other:
            return "Собеседник говорит"
        }
    }
}

enum LiveTranslateButtonState: Equatable, Sendable {
    case ready
    case recording
    case processing
    case speaking
    case locked
    case error(String)

    var title: String {
        switch self {
        case .ready:
            return "Нажмите и держите"
        case .recording:
            return "Слушаю..."
        case .processing:
            return "Перевожу..."
        case .speaking:
            return "Озвучиваю..."
        case .locked:
            return "Ожидание"
        case .error:
            return "Ошибка"
        }
    }
}

struct LiveTranslateLanguage: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let openAICode: String?
    let supportsAutoDetect: Bool

    static let supported: [LiveTranslateLanguage] = [
        LiveTranslateLanguage(id: "auto", title: "Auto", openAICode: nil, supportsAutoDetect: true),
        LiveTranslateLanguage(id: "ru", title: "Русский", openAICode: "ru", supportsAutoDetect: false),
        LiveTranslateLanguage(id: "en", title: "English", openAICode: "en", supportsAutoDetect: false),
        LiveTranslateLanguage(id: "es", title: "Español", openAICode: "es", supportsAutoDetect: false),
        LiveTranslateLanguage(id: "fr", title: "Français", openAICode: "fr", supportsAutoDetect: false),
        LiveTranslateLanguage(id: "de", title: "Deutsch", openAICode: "de", supportsAutoDetect: false),
        LiveTranslateLanguage(id: "it", title: "Italiano", openAICode: "it", supportsAutoDetect: false),
        LiveTranslateLanguage(id: "tr", title: "Türkçe", openAICode: "tr", supportsAutoDetect: false),
        LiveTranslateLanguage(id: "ar", title: "العربية", openAICode: "ar", supportsAutoDetect: false),
        LiveTranslateLanguage(id: "zh", title: "中文", openAICode: "zh", supportsAutoDetect: false),
        LiveTranslateLanguage(id: "ja", title: "日本語", openAICode: "ja", supportsAutoDetect: false)
    ]

    static func language(for id: String) -> LiveTranslateLanguage {
        supported.first { $0.id == id } ?? supported[1]
    }
}

struct LiveTranslateVoice: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let isRecommended: Bool

    var displayTitle: String {
        isRecommended ? "\(title) (рекомендуется)" : title
    }

    static let realtimeSupported: [LiveTranslateVoice] = [
        LiveTranslateVoice(id: "marin", title: "Marin", isRecommended: true),
        LiveTranslateVoice(id: "cedar", title: "Cedar", isRecommended: true),
        LiveTranslateVoice(id: "alloy", title: "Alloy", isRecommended: false),
        LiveTranslateVoice(id: "ash", title: "Ash", isRecommended: false),
        LiveTranslateVoice(id: "ballad", title: "Ballad", isRecommended: false),
        LiveTranslateVoice(id: "coral", title: "Coral", isRecommended: false),
        LiveTranslateVoice(id: "echo", title: "Echo", isRecommended: false),
        LiveTranslateVoice(id: "sage", title: "Sage", isRecommended: false),
        LiveTranslateVoice(id: "shimmer", title: "Shimmer", isRecommended: false),
        LiveTranslateVoice(id: "verse", title: "Verse", isRecommended: false)
    ]

    static func title(for id: String) -> String {
        realtimeSupported.first { $0.id == id }?.displayTitle ?? id
    }
}

struct LiveTranslateDirection: Sendable {
    let speaker: LiveTranslateSpeaker
    let sourceLanguage: LiveTranslateLanguage
    let targetLanguage: LiveTranslateLanguage

    var targetCode: String {
        targetLanguage.openAICode ?? "en"
    }
}

struct LiveTranslateTurn: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let speaker: LiveTranslateSpeaker
    let sourceLanguage: String
    let targetLanguage: String
    var originalText: String
    var translatedText: String
    var audioFilePath: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        speaker: LiveTranslateSpeaker,
        sourceLanguage: String,
        targetLanguage: String,
        originalText: String,
        translatedText: String,
        audioFilePath: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.speaker = speaker
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.originalText = originalText
        self.translatedText = translatedText
        self.audioFilePath = audioFilePath
        self.createdAt = createdAt
    }
}

struct LiveTranslateTurnResult: Sendable {
    var sourceTranscript: String
    var translatedTranscript: String
    var detectedSourceLanguageCode: String?
    var translatedAudioPCM16: Data
}

enum LiveTranslateAuthMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case directAPIKey
    case ephemeralEndpoint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .directAPIKey:
            return "API Key"
        case .ephemeralEndpoint:
            return "Ephemeral endpoint"
        }
    }
}

enum LiveTranslateError: LocalizedError {
    case missingCredentials
    case missingTargetLanguage
    case microphoneUnavailable
    case emptyAudio
    case emptyTranslation
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Для Live-функций нужен OpenAI API Key или endpoint для ephemeral token."
        case .missingTargetLanguage:
            return "Выберите язык перевода. Auto можно использовать только для языка собеседника."
        case .microphoneUnavailable:
            return "Не удалось получить звук с микрофона."
        case .emptyAudio:
            return "Речь не распознана. Попробуйте говорить ближе к микрофону."
        case .emptyTranslation:
            return "Перевод не получен."
        case .playbackFailed:
            return "Не удалось воспроизвести перевод."
        }
    }
}
