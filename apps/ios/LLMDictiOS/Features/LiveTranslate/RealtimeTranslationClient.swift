import Foundation

struct RealtimeTranslationConfiguration: Sendable {
    let model: String
    let baseURL: String
    let auth: RealtimeAuth
    let voice: String
}

protocol RealtimeTranslationClientProtocol: AnyObject, Sendable {
    func translateTurn(
        audioChunks: AsyncThrowingStream<Data, Error>,
        direction: LiveTranslateDirection,
        configuration: RealtimeTranslationConfiguration
    ) async throws -> LiveTranslateTurnResult
}

final class RealtimeTranslationClient: RealtimeTranslationClientProtocol {
    private let session: URLSession
    private let decoder = RealtimeTranslationEventDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func translateTurn(
        audioChunks: AsyncThrowingStream<Data, Error>,
        direction: LiveTranslateDirection,
        configuration: RealtimeTranslationConfiguration
    ) async throws -> LiveTranslateTurnResult {
        guard direction.targetLanguage.openAICode != nil else {
            throw LiveTranslateError.missingTargetLanguage
        }

        let task = try makeTask(configuration: configuration)
        task.resume()
        try await sendSessionUpdate(task: task, direction: direction, configuration: configuration)

        let collector = EventCollector()
        let receiveTask = Task {
            do {
                try await self.receiveEvents(task: task, collector: collector)
            } catch is CancellationError {
                await collector.setReceiverFinished()
            } catch {
                await collector.setError(error)
            }
        }
        defer {
            receiveTask.cancel()
            task.cancel(with: .normalClosure, reason: nil)
        }

        var sentAnyAudio = false
        do {
            for try await chunk in audioChunks {
                sentAnyAudio = true
                try await sendAudio(chunk, task: task)
            }
        } catch is CancellationError {
            task.cancel(with: .goingAway, reason: nil)
            throw CancellationError()
        }

        guard sentAnyAudio else {
            task.cancel(with: .goingAway, reason: nil)
            throw LiveTranslateError.emptyAudio
        }

        try await sendTrailingSilence(task: task)
        let result = try await waitForResult(collector: collector)
        guard result.sourceTranscript.isEmpty == false || result.translatedTranscript.isEmpty == false || result.translatedAudioPCM16.isEmpty == false else {
            throw LiveTranslateError.emptyTranslation
        }
        return result
    }

    private func makeTask(configuration: RealtimeTranslationConfiguration) throws -> URLSessionWebSocketTask {
        let base = configuration.baseURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlString = "\(base)/realtime/translations?model=\(configuration.model)"
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        switch configuration.auth {
        case let .bearer(token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("llmdict-ios", forHTTPHeaderField: "OpenAI-Safety-Identifier")
        return session.webSocketTask(with: request)
    }

    private func sendSessionUpdate(
        task: URLSessionWebSocketTask,
        direction: LiveTranslateDirection,
        configuration: RealtimeTranslationConfiguration
    ) async throws {
        let payload: [String: Any] = [
            "type": "session.update",
            "session": [
                "audio": [
                    "input": [
                        "transcription": [
                            "model": "gpt-realtime-whisper"
                        ],
                        "noise_reduction": NSNull()
                    ],
                    "output": [
                        "language": direction.targetCode
                    ]
                ]
            ]
        ]
        try await sendJSON(payload, task: task)
    }

    private func sendAudio(_ data: Data, task: URLSessionWebSocketTask) async throws {
        let payload: [String: Any] = [
            "type": "session.input_audio_buffer.append",
            "audio": data.base64EncodedString()
        ]
        try await sendJSON(payload, task: task)
    }

    private func sendTrailingSilence(task: URLSessionWebSocketTask) async throws {
        // Realtime Translation emits continuously; a longer tail prevents clipping the final translated phrase.
        let silenceChunk = Data(repeating: 0, count: 4_800)
        for _ in 0..<20 {
            try await sendAudio(silenceChunk, task: task)
        }
    }

    private func waitForResult(collector: EventCollector) async throws -> LiveTranslateTurnResult {
        var stableTicks = 0
        var lastChangeCount = -1
        var sawOutput = false

        for _ in 0..<150 {
            if let error = await collector.error {
                throw error
            }

            let snapshot = await collector.snapshot()
            sawOutput = sawOutput || snapshot.hasOutput

            if snapshot.changeCount == lastChangeCount {
                stableTicks += 1
            } else {
                stableTicks = 0
                lastChangeCount = snapshot.changeCount
            }

            if snapshot.outputDone && stableTicks >= 3 {
                return snapshot.result
            }

            if sawOutput && stableTicks >= 30 {
                return snapshot.result
            }

            try await Task.sleep(for: .milliseconds(100))
        }

        if let error = await collector.error {
            throw error
        }

        return await collector.result()
    }

    private func sendJSON(_ payload: [String: Any], task: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let string = String(decoding: data, as: UTF8.self)
        try await task.send(.string(string))
    }

    private func receiveEvents(task: URLSessionWebSocketTask, collector: EventCollector) async throws {
        while Task.isCancelled == false {
            let message = try await task.receive()
            let data: Data
            switch message {
            case let .data(value):
                data = value
            case let .string(value):
                data = Data(value.utf8)
            @unknown default:
                continue
            }

            switch decoder.decode(data) {
            case let .outputAudio(audio):
                await collector.appendAudio(audio)
            case let .inputTranscriptDelta(delta):
                await collector.appendSource(delta)
            case let .outputTranscriptDelta(delta):
                await collector.appendTranslation(delta)
            case let .inputLanguage(language):
                await collector.setLanguage(language)
            case .outputDone:
                await collector.setOutputDone()
            case let .error(message):
                throw NSError(domain: "RealtimeTranslationClient", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: message
                ])
            case .ignored:
                break
            }
        }
    }
}

private actor EventCollector {
    private var source = ""
    private var translation = ""
    private var language: String?
    private var audio = Data()
    private var changes = 0
    private var didReceiveOutputDone = false
    private(set) var error: Error?

    struct Snapshot: Sendable {
        let result: LiveTranslateTurnResult
        let changeCount: Int
        let outputDone: Bool

        var hasOutput: Bool {
            result.sourceTranscript.isEmpty == false ||
                result.translatedTranscript.isEmpty == false ||
                result.translatedAudioPCM16.isEmpty == false
        }
    }

    func appendSource(_ value: String) {
        guard value.isEmpty == false else { return }
        source += value
        changes += 1
    }

    func appendTranslation(_ value: String) {
        guard value.isEmpty == false else { return }
        translation += value
        changes += 1
    }

    func appendAudio(_ value: Data) {
        guard value.isEmpty == false else { return }
        audio.append(value)
        changes += 1
    }

    func setLanguage(_ value: String) {
        language = value
        changes += 1
    }

    func setOutputDone() {
        didReceiveOutputDone = true
        changes += 1
    }

    func setError(_ value: Error) {
        error = value
    }

    func setReceiverFinished() {
        changes += 1
    }

    func snapshot() -> Snapshot {
        Snapshot(result: result(), changeCount: changes, outputDone: didReceiveOutputDone)
    }

    func result() -> LiveTranslateTurnResult {
        LiveTranslateTurnResult(
            sourceTranscript: source.trimmingCharacters(in: .whitespacesAndNewlines),
            translatedTranscript: translation.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedSourceLanguageCode: language,
            translatedAudioPCM16: audio
        )
    }
}
