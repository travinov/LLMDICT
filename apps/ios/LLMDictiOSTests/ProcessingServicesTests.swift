import XCTest
@testable import LLMDictiOS

@MainActor
final class ProcessingServicesTests: XCTestCase {
    override func tearDownWithError() throws {
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.requests = []
    }

    func testOpenAITranscribeUsesGpt4oTranscribeModelAndDoesNotSendPromptFields() async throws {
        let session = makeSession()
        let expectedPathSuffix = "/audio/transcriptions"

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            let path = try XCTUnwrap(request.url?.path)
            XCTAssertTrue(path.hasSuffix(expectedPathSuffix))

            let body = try XCTUnwrap(self.bodyData(for: request))
            let bodyString = try XCTUnwrap(String(data: body, encoding: .utf8))
            XCTAssertTrue(bodyString.contains("name=\"model\""))
            XCTAssertTrue(bodyString.contains("gpt-4o-transcribe"))
            XCTAssertFalse(bodyString.contains("name=\"prompt\""))
            XCTAssertFalse(bodyString.contains("name=\"template\""))

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, #"{"text":"raw transcript"}"#.data(using: .utf8)!)
        }

        let service = TranscriptionService(session: session)
        let transcript = try await service.transcribe(
            recordingURL: try makeAudioFile(),
            settings: makeSettings(provider: .openAITranscribe)
        )

        XCTAssertEqual(transcript, "raw transcript")
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }

    func testOpenAITranscribeMiniUsesMiniModelInMultipartBody() async throws {
        let session = makeSession()

        MockURLProtocol.requestHandler = { request in
            let body = try XCTUnwrap(self.bodyData(for: request))
            let bodyString = try XCTUnwrap(String(data: body, encoding: .utf8))
            XCTAssertTrue(bodyString.contains("gpt-4o-mini-transcribe"))

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, #"{"text":"mini transcript"}"#.data(using: .utf8)!)
        }

        let service = TranscriptionService(session: session)
        let transcript = try await service.transcribe(
            recordingURL: try makeAudioFile(),
            settings: makeSettings(provider: .openAITranscribeMini)
        )

        XCTAssertEqual(transcript, "mini transcript")
    }

    func testOpenAITranscribeExplainsRegional403() async throws {
        let session = makeSession()

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 403,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = #"{"error":{"message":"Country, region, or territory not supported","code":"unsupported_country_region_territory"}}"#
                .data(using: .utf8)!
            return (response, data)
        }

        let service = TranscriptionService(session: session)
        do {
            _ = try await service.transcribe(
                recordingURL: try makeAudioFile(),
                settings: makeSettings(provider: .openAITranscribe)
            )
            XCTFail("Expected regional restriction")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "OpenAI недоступен из текущего региона при операции «распознавание записи» (HTTP 403). Подключите VPN или укажите доступный совместимый Base URL и повторите запрос."
            )
        }
    }

    func testOpenAI403WithoutRegionalCodeExplainsProjectAccess() {
        let data = #"{"error":{"message":"Project does not have access to model"}}"#.data(using: .utf8)!
        let error = OpenAIHTTPError.make(
            operation: "распознавание записи",
            statusCode: 403,
            data: data
        )

        XCTAssertEqual(
            error.localizedDescription,
            "API Key или проект не имеет доступа к операции «распознавание записи» или выбранной модели (HTTP 403). Проверьте биллинг и разрешения проекта OpenAI. Детали OpenAI: Project does not have access to model"
        )
    }

    func testOpenAITranscribeRejectsInvalidBaseURLWithoutStartingRequest() async throws {
        let service = TranscriptionService(session: makeSession())

        do {
            _ = try await service.transcribe(
                recordingURL: try makeAudioFile(),
                settings: makeSettings(baseURL: "http://[")
            )
            XCTFail("Expected an invalid base URL error")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .badURL)
        } catch {
            XCTFail("Expected URLError.badURL, got \(error)")
        }

        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testRealtimeTranscriptionEventDecoderParsesCommittedDeltaCompletedAndError() throws {
        let committed = try RealtimeTranscriptionEventDecoder.decode(
            Self.jsonData([
                "type": "input_audio_buffer.committed",
                "item_id": "item-1",
                "previous_item_id": "item-0"
            ])
        )
        XCTAssertEqual(committed, .committed(itemID: "item-1", previousItemID: "item-0"))

        let delta = try RealtimeTranscriptionEventDecoder.decode(
            Self.jsonData([
                "type": "conversation.item.input_audio_transcription.delta",
                "item_id": "item-1",
                "delta": "hello"
            ])
        )
        XCTAssertEqual(delta, .delta(itemID: "item-1", text: "hello"))

        let completed = try RealtimeTranscriptionEventDecoder.decode(
            Self.jsonData([
                "type": "conversation.item.input_audio_transcription.completed",
                "item_id": "item-1",
                "transcript": "hello world"
            ])
        )
        XCTAssertEqual(completed, .completed(itemID: "item-1", transcript: "hello world"))

        let error = try RealtimeTranscriptionEventDecoder.decode(
            Self.jsonData([
                "type": "error",
                "error": ["message": "server exploded"]
            ])
        )
        XCTAssertEqual(error, .error("server exploded"))
    }

    func testLiveTranscriptAssemblerKeepsPreviousItemOrderingWhenCompletedArrivesOutOfOrder() async {
        let assembler = LiveTranscriptAssembler()

        await assembler.noteCommitted(itemID: "item-1", previousItemID: nil)
        await assembler.complete(itemID: "item-2", transcript: " second ")
        await assembler.noteCommitted(itemID: "item-2", previousItemID: "item-1")
        await assembler.noteCommitted(itemID: "item-3", previousItemID: "item-2")
        await assembler.complete(itemID: "item-1", transcript: "first")
        await assembler.complete(itemID: "item-3", transcript: "third")

        let snapshot = await assembler.snapshot()
        let completedCount = await assembler.completedCount()
        XCTAssertEqual(snapshot.finalText, "first second third")
        XCTAssertEqual(snapshot.partialText, "")
        XCTAssertEqual(completedCount, 3)
    }

    func testWebSocketURLBuildsRealtimeEndpointAndRejectsInvalidBaseURL() throws {
        let url = try RealtimeTranscriptionClient.webSocketURL(baseURL: "https://api.openai.com/v1/")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "api.openai.com")
        XCTAssertEqual(components.path, "/v1/realtime")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "intent", value: "transcription")])
        XCTAssertFalse(components.queryItems?.contains(where: { $0.name == "model" }) ?? false)

        XCTAssertThrowsError(
            try RealtimeTranscriptionClient.webSocketURL(baseURL: "http://[")
        ) { error in
            guard let liveError = error as? LiveTranscriptionError else {
                return XCTFail("Expected LiveTranscriptionError.invalidBaseURL, got \(error)")
            }
            guard case .invalidBaseURL = liveError else {
                return XCTFail("Expected LiveTranscriptionError.invalidBaseURL, got \(liveError)")
            }
        }
    }

    func testModelURLBuildsExpectedModelsEndpoint() throws {
        let url = try RealtimeTranscriptionClient.modelURL(
            baseURL: "https://api.openai.com/v1",
            model: "gpt-realtime-whisper"
        )
        XCTAssertEqual(url.absoluteString, "https://api.openai.com/v1/models/gpt-realtime-whisper")
    }

    func testOpenAIErrorMessagePrefersServerMessageAndFallsBackToUnknownMessage() throws {
        let serverMessage = try Self.jsonData([
            "error": [
                "message": "handshake denied"
            ]
        ])
        XCTAssertEqual(
            RealtimeTranscriptionClient.openAIErrorMessage(from: serverMessage),
            "handshake denied"
        )

        let missingMessage = try Self.jsonData([
            "error": [:]
        ])
        XCTAssertNil(RealtimeTranscriptionClient.openAIErrorMessage(from: missingMessage))
    }

    func testConnectionMessageIncludesHTTPStatusAndServerMessage() {
        XCTAssertEqual(
            RealtimeTranscriptionClient.connectionMessage(statusCode: 401, model: "gpt-realtime-whisper", serverMessage: nil),
            "OpenAI отклонил API Key (HTTP 401). Проверьте ключ в настройках."
        )
        XCTAssertEqual(
            RealtimeTranscriptionClient.connectionMessage(statusCode: 403, model: "gpt-realtime-whisper", serverMessage: "forbidden"),
            "API Key или проект не имеет доступа к Realtime API (HTTP 403). forbidden"
        )
        XCTAssertEqual(
            RealtimeTranscriptionClient.connectionMessage(
                statusCode: 403,
                model: "gpt-realtime-whisper",
                serverMessage: "Country, region, or territory not supported"
            ),
            "OpenAI Realtime недоступен из текущего региона (HTTP 403). Подключите VPN или укажите доступный совместимый Base URL."
        )
        XCTAssertEqual(
            RealtimeTranscriptionClient.connectionMessage(statusCode: 404, model: "gpt-realtime-whisper", serverMessage: nil),
            "Realtime-модель gpt-realtime-whisper недоступна для этого проекта (HTTP 404)."
        )
        XCTAssertEqual(
            RealtimeTranscriptionClient.connectionMessage(statusCode: 429, model: "gpt-realtime-whisper", serverMessage: "rate limited"),
            "OpenAI отклонил запрос из-за квоты или лимита (HTTP 429). rate limited"
        )
    }

    func testLiveTranscriptionStoreSaveLoadAndClear() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveTranscriptionStoreTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("latest_transcript.txt")
        let store = LiveTranscriptionStore(fileURL: fileURL)

        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(store.load(), "")

        try store.save("first line\nsecond line")
        XCTAssertEqual(store.load(), "first line\nsecond line")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        try store.clear()
        XCTAssertEqual(store.load(), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        try store.clear()
    }

    func testAppSettingsDefaultsAndPersistenceForLiveTranscribeLanguageAndDelay() throws {
        let suiteName = "ProcessingServicesTests.LiveTranscribe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults, credentialStore: InMemoryCredentialStore())
        XCTAssertEqual(settings.liveTranscribeLanguageCode, "ru")
        XCTAssertEqual(settings.liveTranscribeDelay, .low)

        settings.liveTranscribeLanguageCode = "en-US"
        settings.liveTranscribeDelay = .high
        XCTAssertEqual(settings.liveTranscribeLanguageCode, "en")

        let reloaded = AppSettings(defaults: defaults, credentialStore: InMemoryCredentialStore())
        XCTAssertEqual(reloaded.liveTranscribeLanguageCode, "en")
        XCTAssertEqual(reloaded.liveTranscribeDelay, .high)

        reloaded.liveTranscribeLanguageCode = "zz-ZZ"
        XCTAssertEqual(reloaded.liveTranscribeLanguageCode, "ru")
    }

    func testTextProcessingServicePostsToResponsesWithLunaInstructionsAndInput() async throws {
        let session = makeSession()

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            let path = try XCTUnwrap(request.url?.path)
            XCTAssertTrue(path.hasSuffix("/responses"))

            let body = try XCTUnwrap(self.bodyData(for: request))
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "gpt-5.6-luna")
            XCTAssertEqual(json["instructions"] as? String, "Сформатируй текст как протокол.")
            XCTAssertEqual(json["input"] as? String, "Выдели ключевые факты.\n\nсырой текст")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, #"{"output":[{"content":[{"type":"output_text","text":"formatted"}]}]}"#.data(using: .utf8)!)
        }

        let service = TextProcessingService(session: session)
        let formatted = try await service.process(
            rawTranscript: "сырой текст",
            prompt: "{system}\nСформатируй текст как протокол.\n{user}\nВыдели ключевые факты.",
            settings: makeSettings(processingModelProfile: .gpt56Luna)
        )

        XCTAssertEqual(formatted, "formatted")
    }

    func testTextProcessingServiceAggregatesMultipleOutputTextFragments() async throws {
        let session = makeSession()

        MockURLProtocol.requestHandler = { request in
            let body = try XCTUnwrap(self.bodyData(for: request))
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "gpt-5.6-terra")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (
                response,
                #"""
                {
                  "output": [
                    { "content": [
                      { "type": "output_text", "text": "  первая строка  " },
                      { "type": "refusal", "text": "ignore" }
                    ]},
                    { "content": [
                      { "type": "output_text", "text": "\nвторая строка\n" }
                    ]}
                  ]
                }
                """#.data(using: .utf8)!
            )
        }

        let service = TextProcessingService(session: session)
        let formatted = try await service.process(
            rawTranscript: "сырой текст",
            prompt: "{user}\nСделай список.",
            settings: makeSettings(processingModelProfile: .gpt56Terra)
        )

        XCTAssertEqual(formatted, "первая строка\nвторая строка")
    }

    func testAudioEnhancementBoostsQuietMonoSpeechAndLimitsPeak() async throws {
        let service = AudioEnhancementService()
        let workDirectory = try makeWorkDirectory()
        let sourceURL = workDirectory.appendingPathComponent("quiet-input.wav")
        let destinationURL = workDirectory.appendingPathComponent("quiet-output.enhanced.wav")

        let sampleRate = 16_000.0
        let samples = makeSyntheticSpeechSamples(sampleRate: sampleRate, durationSeconds: 1.2)
        try writePCMWave(samples: samples, sampleRate: sampleRate, to: sourceURL)

        let inputStats = try analyzeWave(at: sourceURL)
        let report = try await service.enhance(sourceURL: sourceURL, destinationURL: destinationURL)
        let outputStats = try analyzeWave(at: destinationURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertGreaterThan(outputStats.rmsDecibels, inputStats.rmsDecibels + 6)
        XCTAssertGreaterThan(outputStats.rmsDecibels, -22)
        XCTAssertLessThan(outputStats.peakDecibels, -0.9)
        XCTAssertGreaterThan(report.normalizationGainDecibels, 0)
        XCTAssertLessThanOrEqual(report.outputPeakDecibels, -0.9)
    }

    func testAudioEnhancementStrengthControlsNoiseSuppressionAndPreservesLength() async throws {
        let service = AudioEnhancementService()
        let workDirectory = try makeWorkDirectory()
        let sourceURL = workDirectory.appendingPathComponent("speech-plus-noise.wav")
        let weakURL = workDirectory.appendingPathComponent("speech-plus-noise-weak.enhanced.wav")
        let strongURL = workDirectory.appendingPathComponent("speech-plus-noise-strong.enhanced.wav")

        let sampleRate = 16_000.0
        let samples = makeSyntheticSpeechWithStationaryNoiseSamples(sampleRate: sampleRate, durationSeconds: 2.0)
        try writePCMWave(samples: samples, sampleRate: sampleRate, to: sourceURL)

        let inputSamples = try loadPCM16Samples(at: sourceURL)
        let weakReport = try await service.enhance(sourceURL: sourceURL, destinationURL: weakURL, denoiseStrength: 0)
        let strongReport = try await service.enhance(sourceURL: sourceURL, destinationURL: strongURL, denoiseStrength: 1)
        let weakSamples = try loadPCM16Samples(at: weakURL)
        let strongSamples = try loadPCM16Samples(at: strongURL)

        let noiseRange = 0..<(Int(sampleRate * 0.45))
        let speechRange = Int(sampleRate * 0.9)..<Int(sampleRate * 1.5)

        XCTAssertEqual(weakSamples.count, inputSamples.count)
        XCTAssertEqual(strongSamples.count, inputSamples.count)
        XCTAssertLessThanOrEqual(weakReport.outputPeakDecibels, -0.5)
        XCTAssertLessThanOrEqual(strongReport.outputPeakDecibels, -0.5)

        let weakNoiseToSpeech = ratioDecibels(
            noiseRMS: rms(of: weakSamples, in: noiseRange),
            speechRMS: rms(of: weakSamples, in: speechRange)
        )
        let strongNoiseToSpeech = ratioDecibels(
            noiseRMS: rms(of: strongSamples, in: noiseRange),
            speechRMS: rms(of: strongSamples, in: speechRange)
        )

        XCTAssertLessThan(strongNoiseToSpeech, weakNoiseToSpeech - 1.0)
    }

    func testAudioEnhancementKeepsBurstPeakNearOriginalPositionWhenStrengthIsZero() async throws {
        let service = AudioEnhancementService()
        let workDirectory = try makeWorkDirectory()
        let sourceURL = workDirectory.appendingPathComponent("burst-input.wav")
        let destinationURL = workDirectory.appendingPathComponent("burst-output.enhanced.wav")

        let sampleRate = 16_000.0
        let samples = makeBurstSamples(
            sampleRate: sampleRate,
            durationSeconds: 0.9,
            burstStartIndex: 4_000,
            burstLength: 7
        )
        try writePCMWave(samples: samples, sampleRate: sampleRate, to: sourceURL)

        let inputSamples = try loadPCM16Samples(at: sourceURL)
        let report = try await service.enhance(sourceURL: sourceURL, destinationURL: destinationURL, denoiseStrength: 0)
        let outputSamples = try loadPCM16Samples(at: destinationURL)

        XCTAssertEqual(outputSamples.count, inputSamples.count)
        XCTAssertLessThanOrEqual(report.outputPeakDecibels, -0.5)

        let inputPeakIndex = maxAbsSampleIndex(in: inputSamples)
        let outputPeakIndex = maxAbsSampleIndex(in: outputSamples)
        XCTAssertLessThanOrEqual(abs(outputPeakIndex - inputPeakIndex), 32)
    }

    func testAudioEnhancementHandlesVeryShortSilentFile() async throws {
        let service = AudioEnhancementService()
        let workDirectory = try makeWorkDirectory()
        let sourceURL = workDirectory.appendingPathComponent("silence-input.wav")
        let destinationURL = workDirectory.appendingPathComponent("silence-output.enhanced.wav")

        try writePCMWave(samples: Array(repeating: 0, count: 8), sampleRate: 16_000, to: sourceURL)

        let report = try await service.enhance(sourceURL: sourceURL, destinationURL: destinationURL)
        let outputStats = try analyzeWave(at: destinationURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertLessThanOrEqual(outputStats.peakAmplitude, 0.000_1)
        XCTAssertLessThanOrEqual(outputStats.rmsAmplitude, 0.000_1)
        XCTAssertLessThanOrEqual(report.outputPeakDecibels, -80)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data("wave".utf8).write(to: url, options: .atomic)
        return url
    }

    private static func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read < 0 {
                return nil
            }
            if read == 0 {
                break
            }
            data.append(buffer, count: read)
        }
        return data
    }

    private func makeSettings(
        provider: TranscriptionProvider = .openAITranscribe,
        processingModelProfile: ProcessingModelProfile = .gpt56Luna,
        baseURL: String = "https://example.test/v1"
    ) -> SettingsSnapshot {
        let defaults = UserDefaults(suiteName: "ProcessingServicesTests.\(UUID().uuidString)")!

        let settings = AppSettings(defaults: defaults, credentialStore: InMemoryCredentialStore())
        settings.openAIAPIKey = "test-openai-key"
        settings.openAIBaseURL = baseURL
        settings.provider = provider
        settings.processingModelProfile = processingModelProfile
        return SettingsSnapshot(settings: settings)
    }

    private func makeWorkDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AudioEnhancementServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeSyntheticSpeechSamples(sampleRate: Double, durationSeconds: Double) -> [Float] {
        let sampleCount = Int(sampleRate * durationSeconds)
        var samples: [Float] = []
        samples.reserveCapacity(sampleCount)

        for index in 0..<sampleCount {
            let t = Double(index) / sampleRate
            let fundamental = sin(2 * Double.pi * 190 * t) * 0.028
            let formant = sin(2 * Double.pi * 930 * t) * 0.008
            let breath = sin(2 * Double.pi * 2_700 * t) * 0.003
            let dcOffset = 0.010
            samples.append(Float(fundamental + formant + breath + dcOffset))
        }

        return samples
    }

    private func makeSyntheticSpeechWithStationaryNoiseSamples(sampleRate: Double, durationSeconds: Double) -> [Float] {
        let sampleCount = Int(sampleRate * durationSeconds)
        var samples: [Float] = []
        samples.reserveCapacity(sampleCount)

        var seed: UInt64 = 0x4d59_5df4_d0f3_3173

        func nextNoise() -> Float {
            seed = seed &* 6364136223846793005 &+ 1
            let upperBits = UInt32(truncatingIfNeeded: seed >> 32)
            let signed = Int64(upperBits) - Int64(Int32.max)
            return Float(signed) / Float(Int32.max)
        }

        for index in 0..<sampleCount {
            let t = Double(index) / sampleRate
            let speechEnvelope: Double
            switch t {
            case ..<0.55:
                speechEnvelope = 0
            case 0.55..<0.75:
                speechEnvelope = (t - 0.55) / 0.20
            case 0.75..<1.60:
                speechEnvelope = 1
            case 1.60..<1.80:
                speechEnvelope = (1.80 - t) / 0.20
            default:
                speechEnvelope = 0
            }

            let noise = nextNoise() * 0.010
            let speech = speechEnvelope * (
                sin(2 * Double.pi * 185 * t) * 0.040 +
                sin(2 * Double.pi * 930 * t) * 0.012 +
                sin(2 * Double.pi * 2_500 * t) * 0.004
            )
            samples.append(noise + Float(speech))
        }

        return samples
    }

    private func makeBurstSamples(sampleRate: Double, durationSeconds: Double, burstStartIndex: Int, burstLength: Int) -> [Float] {
        let sampleCount = Int(sampleRate * durationSeconds)
        var samples = Array(repeating: Float(0), count: sampleCount)
        let shape: [Float] = [0.35, 0.72, 1.0, 0.72, 0.35, 0.18, 0.08]
        let start = max(0, min(sampleCount, burstStartIndex))
        let end = max(start, min(sampleCount, burstStartIndex + burstLength))

        for index in start..<end {
            let offset = index - start
            samples[index] = shape[offset] * 0.92
        }

        return samples
    }

    private func writePCMWave(samples: [Float], sampleRate: Double, to url: URL) throws {
        var data = Data()
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = UInt32(sampleRate) * UInt32(blockAlign)
        let dataSize = UInt32(samples.count) * UInt32(blockAlign)

        data.append(contentsOf: "RIFF".utf8)
        data.append(littleEndian: UInt32(36) + dataSize)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: channels)
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: byteRate)
        data.append(littleEndian: blockAlign)
        data.append(littleEndian: bitsPerSample)
        data.append(contentsOf: "data".utf8)
        data.append(littleEndian: dataSize)

        for sample in samples {
            let clamped = max(-1.0, min(1.0, Double(sample)))
            let intSample = Int16((clamped * Double(Int16.max)).rounded())
            data.append(littleEndian: intSample)
        }

        try data.write(to: url, options: .atomic)
    }

    private func analyzeWave(at url: URL) throws -> WaveStats {
        let data = try Data(contentsOf: url)
        let parsed = try parseWav(data: data)
        var sumSquares = 0.0
        var peak = 0.0
        var totalSamples = 0

        switch parsed.audioFormat {
        case 1 where parsed.bitsPerSample == 16:
            let bytesPerSample = Int(parsed.bitsPerSample / 8)
            let frameSize = bytesPerSample * Int(parsed.channels)
            let availableFrames = parsed.data.count / frameSize
            for frameIndex in 0..<availableFrames {
                var sample = 0.0
                for channel in 0..<Int(parsed.channels) {
                    let offset = parsed.data.startIndex + (frameIndex * frameSize) + (channel * bytesPerSample)
                    let rawValue = parsed.data[offset..<(offset + bytesPerSample)].withUnsafeBytes {
                        $0.load(as: Int16.self)
                    }
                    sample += Double(Int16(littleEndian: rawValue)) / Double(Int16.max)
                }
                sample /= Double(parsed.channels)
                sumSquares += sample * sample
                peak = max(peak, abs(sample))
                totalSamples += 1
            }
        case 3 where parsed.bitsPerSample == 32:
            let bytesPerSample = Int(parsed.bitsPerSample / 8)
            let frameSize = bytesPerSample * Int(parsed.channels)
            let availableFrames = parsed.data.count / frameSize
            for frameIndex in 0..<availableFrames {
                var sample = 0.0
                for channel in 0..<Int(parsed.channels) {
                    let offset = parsed.data.startIndex + (frameIndex * frameSize) + (channel * bytesPerSample)
                    let rawValue = parsed.data[offset..<(offset + bytesPerSample)].withUnsafeBytes {
                        $0.load(as: Float32.self)
                    }
                    sample += Double(Float32(bitPattern: UInt32(littleEndian: rawValue.bitPattern)))
                }
                sample /= Double(parsed.channels)
                sumSquares += sample * sample
                peak = max(peak, abs(sample))
                totalSamples += 1
            }
        default:
            throw XCTSkip("Unsupported analysis format")
        }

        let rms = totalSamples > 0 ? sqrt(sumSquares / Double(totalSamples)) : 0
        return WaveStats(rmsAmplitude: rms, peakAmplitude: peak, sampleCount: totalSamples)
    }

    private func loadPCM16Samples(at url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        let parsed = try parseWav(data: data)
        guard parsed.audioFormat == 1, parsed.bitsPerSample == 16 else {
            throw XCTSkip("Unsupported analysis format")
        }

        let bytesPerSample = Int(parsed.bitsPerSample / 8)
        let frameSize = bytesPerSample * Int(parsed.channels)
        let availableFrames = parsed.data.count / frameSize
        var samples: [Float] = []
        samples.reserveCapacity(availableFrames)

        for frameIndex in 0..<availableFrames {
            var sample = 0.0
            for channel in 0..<Int(parsed.channels) {
                let offset = parsed.data.startIndex + (frameIndex * frameSize) + (channel * bytesPerSample)
                let rawValue = parsed.data[offset..<(offset + bytesPerSample)].withUnsafeBytes {
                    $0.load(as: Int16.self)
                }
                sample += Double(Int16(littleEndian: rawValue)) / Double(Int16.max)
            }
            samples.append(Float(sample / Double(parsed.channels)))
        }

        return samples
    }

    private func rms(of samples: [Float], in range: Range<Int>) -> Double {
        guard range.isEmpty == false else { return 0 }

        let clampedLowerBound = max(0, range.lowerBound)
        let clampedUpperBound = min(samples.count, range.upperBound)
        guard clampedUpperBound > clampedLowerBound else { return 0 }

        var sumSquares = 0.0
        var count = 0
        for index in clampedLowerBound..<clampedUpperBound {
            let sample = Double(samples[index])
            sumSquares += sample * sample
            count += 1
        }
        return count > 0 ? sqrt(sumSquares / Double(count)) : 0
    }

    private func ratioDecibels(noiseRMS: Double, speechRMS: Double) -> Double {
        20 * log10(max(noiseRMS, 0.000_000_001) / max(speechRMS, 0.000_000_001))
    }

    private func maxAbsSampleIndex(in samples: [Float]) -> Int {
        var maxIndex = 0
        var maxValue: Float = 0

        for (index, sample) in samples.enumerated() {
            let magnitude = abs(sample)
            if magnitude > maxValue {
                maxValue = magnitude
                maxIndex = index
            }
        }

        return maxIndex
    }

    private func parseWav(data: Data) throws -> ParsedWave {
        guard data.count >= 44 else {
            throw XCTSkip("Unsupported analysis format")
        }
        guard String(bytes: data[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: data[8..<12], encoding: .ascii) == "WAVE" else {
            throw XCTSkip("Unsupported analysis format")
        }

        var offset = 12
        var audioFormat: UInt16 = 0
        var channels: UInt16 = 0
        var bitsPerSample: UInt16 = 0
        var dataChunk: Data = Data()

        while offset + 8 <= data.count {
            let chunkID = String(bytes: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
            let chunkSize = Int(data[(offset + 4)..<(offset + 8)].withUnsafeBytes {
                $0.load(as: UInt32.self)
            }.littleEndian)
            let chunkStart = offset + 8
            let chunkEnd = min(chunkStart + chunkSize, data.count)

            switch chunkID {
            case "fmt ":
                guard chunkSize >= 16 else { throw XCTSkip("Unsupported analysis format") }
                audioFormat = data[chunkStart..<(chunkStart + 2)].withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
                channels = data[(chunkStart + 2)..<(chunkStart + 4)].withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
                bitsPerSample = data[(chunkStart + 14)..<(chunkStart + 16)].withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
            case "data":
                dataChunk = data.subdata(in: chunkStart..<chunkEnd)
            default:
                break
            }

            offset = chunkStart + chunkSize + (chunkSize % 2)
        }

        guard audioFormat != 0, channels > 0, bitsPerSample != 0 else {
            throw XCTSkip("Unsupported analysis format")
        }

        return ParsedWave(audioFormat: audioFormat, channels: channels, bitsPerSample: bitsPerSample, data: dataChunk)
    }
}

private struct ParsedWave {
    let audioFormat: UInt16
    let channels: UInt16
    let bitsPerSample: UInt16
    let data: Data
}

private struct WaveStats {
    let rmsAmplitude: Double
    let peakAmplitude: Double
    let sampleCount: Int

    var rmsDecibels: Double {
        Self.decibels(amplitude: rmsAmplitude)
    }

    var peakDecibels: Double {
        Self.decibels(amplitude: peakAmplitude)
    }

    private static func decibels(amplitude: Double) -> Double {
        20 * log10(max(amplitude, 0.000_000_001))
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}

private final class InMemoryCredentialStore: CredentialStoring {
    private var credentials: [CredentialKey: String] = [:]

    func credential(for key: CredentialKey) throws -> String? {
        credentials[key]
    }

    func setCredential(_ credential: String, for key: CredentialKey) throws {
        credentials[key] = credential
    }

    func deleteCredential(for key: CredentialKey) throws {
        credentials.removeValue(forKey: key)
    }
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requests.append(request)
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
