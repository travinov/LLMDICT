import Foundation

struct RealtimeTranscriptionConfiguration: Sendable {
    var transcriptionModel = "gpt-realtime-whisper"
    let baseURL: String
    let auth: RealtimeAuth
    let languageCode: String?
    let delay: LiveTranscriptionDelay
}

protocol RealtimeTranscriptionClientProtocol: Sendable {
    func transcribe(
        audioChunks: AsyncThrowingStream<Data, Error>,
        configuration: RealtimeTranscriptionConfiguration,
        onUpdate: @escaping @Sendable (LiveTranscriptionSnapshot) async -> Void
    ) async throws -> String
}

final class RealtimeTranscriptionClient: RealtimeTranscriptionClientProtocol, @unchecked Sendable {
    private static let commitThresholdBytes = 57_600

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func transcribe(
        audioChunks: AsyncThrowingStream<Data, Error>,
        configuration: RealtimeTranscriptionConfiguration,
        onUpdate: @escaping @Sendable (LiveTranscriptionSnapshot) async -> Void
    ) async throws -> String {
        let url = try Self.webSocketURL(baseURL: configuration.baseURL)
        var request = URLRequest(url: url)
        if case .bearer(let token) = configuration.auth {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let socket = session.webSocketTask(with: request)
        let assembler = LiveTranscriptAssembler()
        let receiverState = RealtimeReceiverState()
        socket.resume()

        let receiver = Task {
            do {
                try await Self.receiveEvents(
                    from: socket,
                    assembler: assembler,
                    onUpdate: onUpdate
                )
            } catch is CancellationError {
                // Normal when the requested number of committed turns is complete.
            } catch {
                await receiverState.fail(error)
            }
        }

        defer {
            receiver.cancel()
            socket.cancel(with: .normalClosure, reason: nil)
        }

        do {
            try await sendSessionUpdate(to: socket, configuration: configuration)

            var totalBytes = 0
            var bytesSinceCommit = 0
            var expectedCompletions = 0

            for try await chunk in audioChunks {
                try Task.checkCancellation()
                if let receiverError = await receiverState.error {
                    throw receiverError
                }
                guard chunk.isEmpty == false else { continue }
                try await sendAudio(chunk, to: socket)
                totalBytes += chunk.count
                bytesSinceCommit += chunk.count

                if bytesSinceCommit >= Self.commitThresholdBytes {
                    try await commitAudio(on: socket)
                    expectedCompletions += 1
                    bytesSinceCommit = 0
                }
            }

            guard totalBytes > 0 else {
                throw LiveTranscriptionError.emptyAudio
            }

            if bytesSinceCommit > 0 {
                try await commitAudio(on: socket)
                expectedCompletions += 1
            }

            let transcript = try await waitForCompletion(
                expectedCount: expectedCompletions,
                assembler: assembler,
                receiverState: receiverState
            )
            guard transcript.isEmpty == false else {
                throw LiveTranscriptionError.emptyTranscript
            }
            return transcript
        } catch {
            socket.cancel(with: .goingAway, reason: nil)
            throw await diagnosticError(for: error, configuration: configuration)
        }
    }

    static func webSocketURL(baseURL: String) throws -> URL {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw LiveTranscriptionError.invalidBaseURL
        }

        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        case "wss", "ws":
            break
        default:
            throw LiveTranscriptionError.invalidBaseURL
        }

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/realtime") == false {
            path += "/realtime"
        }
        components.path = path
        components.queryItems = [URLQueryItem(name: "intent", value: "transcription")]

        guard let url = components.url, url.host != nil else {
            throw LiveTranscriptionError.invalidBaseURL
        }
        return url
    }

    static func modelURL(baseURL: String, model: String) throws -> URL {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw LiveTranscriptionError.invalidBaseURL
        }

        guard let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw LiveTranscriptionError.invalidBaseURL
        }

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/models/" + model
        components.query = nil

        guard let url = components.url, url.host != nil else {
            throw LiveTranscriptionError.invalidBaseURL
        }
        return url
    }

    private func sendSessionUpdate(
        to socket: URLSessionWebSocketTask,
        configuration: RealtimeTranscriptionConfiguration
    ) async throws {
        var transcription: [String: Any] = [
            "model": configuration.transcriptionModel,
            "delay": configuration.delay.rawValue
        ]
        if let languageCode = configuration.languageCode, languageCode.isEmpty == false {
            transcription["language"] = languageCode
        }

        let payload: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": transcription,
                        "turn_detection": NSNull()
                    ]
                ]
            ]
        ]
        try await send(payload, to: socket)
    }

    private func sendAudio(_ data: Data, to socket: URLSessionWebSocketTask) async throws {
        try await send([
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString()
        ], to: socket)
    }

    private func commitAudio(on socket: URLSessionWebSocketTask) async throws {
        try await send(["type": "input_audio_buffer.commit"], to: socket)
    }

    private func send(_ payload: [String: Any], to socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw LiveTranscriptionError.server("Не удалось сформировать запрос OpenAI Realtime.")
        }
        try await socket.send(.string(text))
    }

    private static func receiveEvents(
        from socket: URLSessionWebSocketTask,
        assembler: LiveTranscriptAssembler,
        onUpdate: @escaping @Sendable (LiveTranscriptionSnapshot) async -> Void
    ) async throws {
        while Task.isCancelled == false {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case .string(let text):
                data = Data(text.utf8)
            case .data(let rawData):
                data = rawData
            @unknown default:
                continue
            }

            switch try RealtimeTranscriptionEventDecoder.decode(data) {
            case .committed(let itemID, let previousItemID):
                await assembler.noteCommitted(itemID: itemID, previousItemID: previousItemID)
            case .delta(let itemID, let text):
                await assembler.append(text, to: itemID)
                await onUpdate(assembler.snapshot())
            case .completed(let itemID, let transcript):
                await assembler.complete(itemID: itemID, transcript: transcript)
                await onUpdate(assembler.snapshot())
            case .error(let message):
                throw LiveTranscriptionError.server(message)
            case .ignored:
                continue
            }
        }
    }

    private func waitForCompletion(
        expectedCount: Int,
        assembler: LiveTranscriptAssembler,
        receiverState: RealtimeReceiverState
    ) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(18))

        while clock.now < deadline {
            try Task.checkCancellation()
            if let error = await receiverState.error {
                throw error
            }
            if await assembler.completedCount() >= expectedCount {
                return await assembler.snapshot().finalText
            }
            try await Task.sleep(for: .milliseconds(60))
        }

        throw LiveTranscriptionError.timedOut
    }

    private func diagnosticError(
        for originalError: any Error,
        configuration: RealtimeTranscriptionConfiguration
    ) async -> any Error {
        if originalError is LiveTranscriptionError {
            return originalError
        }

        do {
            let url = try Self.modelURL(baseURL: configuration.baseURL, model: configuration.transcriptionModel)
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            if case .bearer(let token) = configuration.auth {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return originalError
            }

            guard (200..<300).contains(http.statusCode) else {
                let serverMessage = Self.openAIErrorMessage(from: data)
                return LiveTranscriptionError.server(
                    Self.connectionMessage(
                        statusCode: http.statusCode,
                        model: configuration.transcriptionModel,
                        serverMessage: serverMessage
                    )
                )
            }

            return LiveTranscriptionError.server(
                "OpenAI API и модель доступны, но WebSocket не подключился. Проверьте VPN, прокси или сетевой фильтр. Детали: \(originalError.localizedDescription)"
            )
        } catch let diagnosticError as LiveTranscriptionError {
            return diagnosticError
        } catch {
            return LiveTranscriptionError.server(
                "Не удалось подключиться ни к OpenAI Realtime, ни к OpenAI REST API. Проверьте интернет, VPN и Base URL. Детали: \(error.localizedDescription)"
            )
        }
    }

    static func openAIErrorMessage(from data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any],
            let message = error["message"] as? String,
            message.isEmpty == false
        else { return nil }
        return message
    }

    static func connectionMessage(statusCode: Int, model: String, serverMessage: String?) -> String {
        let detail = serverMessage.map { " \($0)" } ?? ""
        switch statusCode {
        case 401:
            return "OpenAI отклонил API Key (HTTP 401). Проверьте ключ в настройках.\(detail)"
        case 403:
            if OpenAIHTTPError.isRegionalRestriction(message: serverMessage) {
                return "OpenAI Realtime недоступен из текущего региона (HTTP 403). Подключите VPN или укажите доступный совместимый Base URL."
            }
            return "API Key или проект не имеет доступа к Realtime API (HTTP 403).\(detail)"
        case 404:
            return "Realtime-модель \(model) недоступна для этого проекта (HTTP 404).\(detail)"
        case 429:
            return "OpenAI отклонил запрос из-за квоты или лимита (HTTP 429).\(detail)"
        default:
            return "OpenAI отклонил подключение (HTTP \(statusCode)).\(detail)"
        }
    }
}

private actor RealtimeReceiverState {
    private(set) var error: (any Error)?

    func fail(_ error: any Error) {
        self.error = error
    }
}
