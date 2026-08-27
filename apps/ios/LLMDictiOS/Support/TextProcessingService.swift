import Foundation

enum TextProcessingError: LocalizedError {
    case missingAPIKey
    case missingSberKey
    case invalidSberAuthorizationKey
    case invalidResponse
    case requestFailed(service: String, statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Не задан OpenAI API Key."
        case .missingSberKey:
            return "Не задан ключ GigaChat."
        case .invalidSberAuthorizationKey:
            return "Неверный Sber Authorization Key. Нужна Base64-строка из developers.sber.ru."
        case .invalidResponse:
            return "Сервис оформления вернул неожиданный ответ."
        case let .requestFailed(service, statusCode):
            return "\(service) вернул ошибку HTTP \(statusCode)."
        }
    }
}

final class TextProcessingService: TextProcessingServicing {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func process(rawTranscript: String, prompt: String, settings: SettingsSnapshot) async throws -> String {
        switch settings.provider.normalized {
        case .openAITranscribe, .openAITranscribeMini:
            return try await processWithOpenAI(
                rawTranscript: rawTranscript,
                prompt: prompt,
                settings: settings
            )
        case .sberSalute:
            return try await processWithGigaChat(
                rawTranscript: rawTranscript,
                prompt: prompt,
                settings: settings
            )
        case .openAIWhisper, .openAIRealtimeWhisper, .openAIGPT4o:
            assertionFailure("Legacy providers must normalize before processing.")
            throw TextProcessingError.invalidResponse
        }
    }

    private func processWithOpenAI(
        rawTranscript: String,
        prompt: String,
        settings: SettingsSnapshot
    ) async throws -> String {
        guard settings.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw TextProcessingError.missingAPIKey
        }

        let parsed = parse(prompt: prompt, fallbackInstruction: "Оформи исходный текст согласно инструкции.")
        var payload: [String: Any] = [
            "model": settings.processingModelProfile.modelID,
            "input": "\(parsed.userInstruction)\n\n\(rawTranscript)"
        ]
        if parsed.system.isEmpty == false {
            payload["instructions"] = parsed.system
        }

        guard let url = URL(string: "\(settings.openAIBaseURL)/responses") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        try validateOpenAI(response: response, data: data)
        return try parseResponsesText(from: data)
    }

    private func parseResponsesText(from data: Data) throws -> String {
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let outputItems = json["output"] as? [[String: Any]]
        else {
            throw TextProcessingError.invalidResponse
        }

        let texts = outputItems.flatMap { item -> [String] in
            guard let contentItems = item["content"] as? [[String: Any]] else { return [] }
            return contentItems.compactMap { content in
                guard content["type"] as? String == "output_text" else { return nil }
                return (content["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }.filter { $0.isEmpty == false }

        guard texts.isEmpty == false else {
            throw TextProcessingError.invalidResponse
        }
        return texts.joined(separator: "\n")
    }

    private func processWithGigaChat(
        rawTranscript: String,
        prompt: String,
        settings: SettingsSnapshot
    ) async throws -> String {
        let authorizationKey = settings.gigaChatAuthKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? settings.sberAuthKey
            : settings.gigaChatAuthKey
        guard authorizationKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw TextProcessingError.missingSberKey
        }

        let token = try await sberToken(authKey: authorizationKey)
        let parsed = parse(prompt: prompt, fallbackInstruction: "Оформи исходный текст согласно инструкции.")
        let payload: [String: Any] = [
            "model": "GigaChat-2",
            "messages": [
                ["role": "system", "content": parsed.system],
                ["role": "user", "content": "\(parsed.userInstruction)\n\n\(rawTranscript)"]
            ],
            "temperature": 0.1
        ]

        var request = URLRequest(url: URL(string: "https://gigachat.devices.sberbank.ru/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data, service: "GigaChat")

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String,
            content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            throw TextProcessingError.invalidResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sberToken(authKey: String) async throws -> String {
        let normalizedKey = try normalizedSberAuthorizationKey(authKey)
        var request = URLRequest(url: URL(string: "https://ngw.devices.sberbank.ru:9443/api/v2/oauth")!)
        request.httpMethod = "POST"
        request.setValue("Basic \(normalizedKey)", forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "RqUID")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "scope=GIGACHAT_API_PERS".data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data, service: "GigaChat OAuth")

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = json["access_token"] as? String
        else {
            throw TextProcessingError.invalidResponse
        }
        return token
    }

    private func validate(response: URLResponse, data: Data, service: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw TextProcessingError.invalidResponse
        }
        guard 200 ..< 300 ~= http.statusCode else {
            let message = String(decoding: data, as: UTF8.self).lowercased()
            if message.contains("credentials doesn't match db data")
                || message.contains("credentials doesnt match db data")
                || message.contains("code\":6")
                || message.contains("\"code\": 6") {
                throw TextProcessingError.invalidSberAuthorizationKey
            }
            throw TextProcessingError.requestFailed(service: service, statusCode: http.statusCode)
        }
    }

    private func validateOpenAI(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw TextProcessingError.invalidResponse
        }
        guard 200 ..< 300 ~= http.statusCode else {
            throw OpenAIHTTPError.make(
                operation: "оформление текста",
                statusCode: http.statusCode,
                data: data
            )
        }
    }

    private func normalizedSberAuthorizationKey(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutScheme: String
        if trimmed.lowercased().hasPrefix("basic ") {
            withoutScheme = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if trimmed.lowercased().hasPrefix("bearer ") {
            withoutScheme = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            withoutScheme = trimmed
        }

        let compact = withoutScheme.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard compact.range(of: "^[A-Za-z0-9+/=]+$", options: .regularExpression) != nil,
              compact.contains(".") == false else {
            throw TextProcessingError.invalidSberAuthorizationKey
        }
        return compact
    }

    private func parse(prompt: String, fallbackInstruction: String) -> ParsedProcessingPrompt {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let systemMarker = trimmed.range(of: "{system}") else {
            return ParsedProcessingPrompt(system: trimmed, userInstruction: fallbackInstruction)
        }

        let afterSystem = trimmed[systemMarker.upperBound...]
        guard let userMarker = afterSystem.range(of: "{user}") else {
            return ParsedProcessingPrompt(
                system: String(afterSystem).trimmingCharacters(in: .whitespacesAndNewlines),
                userInstruction: fallbackInstruction
            )
        }

        let system = afterSystem[..<userMarker.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let user = afterSystem[userMarker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedProcessingPrompt(
            system: system,
            userInstruction: user.isEmpty ? fallbackInstruction : user
        )
    }
}

private struct ParsedProcessingPrompt {
    let system: String
    let userInstruction: String
}
