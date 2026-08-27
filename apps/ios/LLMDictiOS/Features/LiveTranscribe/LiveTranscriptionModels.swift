import Foundation

enum LiveTranscriptionDelay: String, CaseIterable, Codable, Identifiable, Sendable {
    case minimal
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .minimal:
            return "Минимум"
        case .low:
            return "Низкая"
        case .medium:
            return "Средняя"
        case .high:
            return "Высокая"
        case .xhigh:
            return "Максимум"
        }
    }
}

enum LiveTranscriptionState: Equatable, Sendable {
    case idle
    case connecting
    case recording
    case finishing

    var title: String {
        switch self {
        case .idle:
            return "Готово"
        case .connecting:
            return "Подключение…"
        case .recording:
            return "Слушаю и распознаю"
        case .finishing:
            return "Завершаю текст…"
        }
    }

    var isActive: Bool {
        self != .idle
    }
}

struct LiveTranscriptionSnapshot: Equatable, Sendable {
    let finalText: String
    let partialText: String

    var combinedText: String {
        [finalText, partialText]
            .filter { $0.isEmpty == false }
            .joined(separator: finalText.isEmpty || partialText.isEmpty ? "" : " ")
    }
}

enum LiveTranscriptionError: LocalizedError {
    case invalidBaseURL
    case emptyAudio
    case emptyTranscript
    case timedOut
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Некорректный OpenAI Base URL."
        case .emptyAudio:
            return "Микрофон не передал звук."
        case .emptyTranscript:
            return "Речь не распознана. Попробуйте говорить ближе к микрофону."
        case .timedOut:
            return "OpenAI не успел завершить распознавание. Попробуйте ещё раз."
        case .server(let message):
            return message
        }
    }
}
