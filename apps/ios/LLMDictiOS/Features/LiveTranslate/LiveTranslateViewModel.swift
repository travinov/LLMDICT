import Foundation
import Observation

@MainActor
@Observable
final class LiveTranslateViewModel {
    var ownerButtonState: LiveTranslateButtonState = .ready
    var otherButtonState: LiveTranslateButtonState = .ready
    var turns: [LiveTranslateTurn] = []
    var partialOriginalText = ""
    var partialTranslatedText = ""
    var detectedOtherLanguageCode: String?
    var micLevel: Double = 0
    var errorMessage: String?

    private let settings: AppSettings
    private let capture: LiveAudioCaptureService
    private let client: RealtimeTranslationClientProtocol
    private let authProvider: RealtimeAuthProvider
    private let player: LiveTranslatedAudioPlayer
    private let store: LiveTranslateSessionStore

    private var activeSpeaker: LiveTranslateSpeaker?
    private var activeStream: AsyncThrowingStream<Data, Error>?
    private var activeTask: Task<Void, Never>?

    init(
        settings: AppSettings,
        capture: LiveAudioCaptureService? = nil,
        client: RealtimeTranslationClientProtocol? = nil,
        authProvider: RealtimeAuthProvider? = nil,
        player: LiveTranslatedAudioPlayer? = nil,
        store: LiveTranslateSessionStore = LiveTranslateSessionStore()
    ) {
        self.settings = settings
        self.capture = capture ?? LiveAudioCaptureService()
        self.client = client ?? RealtimeTranslationClient()
        self.authProvider = authProvider ?? RealtimeAuthProvider()
        self.player = player ?? LiveTranslatedAudioPlayer()
        self.store = store
        if settings.liveTranslateSaveDialogue {
            self.turns = (try? store.load()) ?? []
        }
    }

    func press(_ speaker: LiveTranslateSpeaker) async {
        guard activeSpeaker == nil else { return }
        errorMessage = nil
        partialOriginalText = ""
        partialTranslatedText = ""

        do {
            let direction = try direction(for: speaker)
            let stream = try await capture.start(maxDuration: settings.liveTranslateMaxTurnDuration)
            activeSpeaker = speaker
            activeStream = stream
            setState(.recording, for: speaker)
            setState(.locked, for: opposite(of: speaker))
            activeTask = Task { [weak self] in
                await self?.translate(stream: stream, direction: direction)
            }
        } catch {
            show(error)
        }
    }

    func release(_ speaker: LiveTranslateSpeaker) async {
        guard activeSpeaker == speaker else { return }
        setState(.processing, for: speaker)
        await capture.stop()
        micLevel = 0
    }

    func stopSpeaking() async {
        player.stop()
        resetButtons()
    }

    func clearDialogue() {
        turns.removeAll()
        try? store.clear()
    }

    func replay(_ turn: LiveTranslateTurn) async {
        guard let path = turn.audioFilePath else { return }
        do {
            try await player.playFile(url: URL(fileURLWithPath: path))
        } catch {
            show(error)
        }
    }

    func refreshMicLevel() {
        micLevel = capture.micLevel
    }

    private func translate(stream: AsyncThrowingStream<Data, Error>, direction: LiveTranslateDirection) async {
        do {
            let auth = try await authProvider.auth(settings: settings)
            let configuration = RealtimeTranslationConfiguration(
                model: settings.liveTranslateModel,
                baseURL: settings.openAIBaseURL,
                auth: auth,
                voice: settings.liveTranslateVoice
            )
            let result = try await client.translateTurn(audioChunks: stream, direction: direction, configuration: configuration)
            try await handle(result: result, direction: direction)
        } catch is CancellationError {
            resetButtons()
        } catch {
            show(error)
        }
    }

    private func handle(result: LiveTranslateTurnResult, direction: LiveTranslateDirection) async throws {
        partialOriginalText = result.sourceTranscript
        partialTranslatedText = result.translatedTranscript

        if
            settings.liveTranslateAutoFillDetectedLanguage,
            direction.speaker == .other,
            let detected = result.detectedSourceLanguageCode,
            detected.isEmpty == false
        {
            detectedOtherLanguageCode = detected
            if settings.liveTranslateOtherLanguageCode == "auto" {
                settings.liveTranslateOtherLanguageCode = detected
            }
        }

        let turnID = UUID()
        let audioFilePath = settings.liveTranslateKeepAudioSnippets
            ? try? store.saveTranslatedAudio(result.translatedAudioPCM16, id: turnID)
            : nil
        let turn = LiveTranslateTurn(
            id: turnID,
            speaker: direction.speaker,
            sourceLanguage: direction.sourceLanguage.title,
            targetLanguage: direction.targetLanguage.title,
            originalText: result.sourceTranscript.isEmpty ? "Аудио без распознанного текста" : result.sourceTranscript,
            translatedText: result.translatedTranscript.isEmpty ? "Перевод получен как аудио" : result.translatedTranscript,
            audioFilePath: audioFilePath
        )
        turns.append(turn)
        persistIfNeeded()

        if settings.liveTranslateAutoSpeak, result.translatedAudioPCM16.isEmpty == false {
            setState(.speaking, for: direction.speaker)
            try await player.play(pcm16: result.translatedAudioPCM16)
        }

        resetButtons()
    }

    private func direction(for speaker: LiveTranslateSpeaker) throws -> LiveTranslateDirection {
        let ownerLanguage = LiveTranslateLanguage.language(for: settings.liveTranslateOwnerLanguageCode)
        let otherLanguage = LiveTranslateLanguage.language(for: settings.liveTranslateOtherLanguageCode)

        switch speaker {
        case .owner:
            guard otherLanguage.openAICode != nil else {
                throw LiveTranslateError.missingTargetLanguage
            }
            return LiveTranslateDirection(speaker: speaker, sourceLanguage: ownerLanguage, targetLanguage: otherLanguage)
        case .other:
            return LiveTranslateDirection(speaker: speaker, sourceLanguage: otherLanguage, targetLanguage: ownerLanguage)
        }
    }

    private func setState(_ state: LiveTranslateButtonState, for speaker: LiveTranslateSpeaker) {
        switch speaker {
        case .owner:
            ownerButtonState = state
        case .other:
            otherButtonState = state
        }
    }

    private func opposite(of speaker: LiveTranslateSpeaker) -> LiveTranslateSpeaker {
        speaker == .owner ? .other : .owner
    }

    private func resetButtons() {
        activeSpeaker = nil
        activeStream = nil
        activeTask = nil
        ownerButtonState = .ready
        otherButtonState = .ready
    }

    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
        if let activeSpeaker {
            setState(.error(error.localizedDescription), for: activeSpeaker)
        }
        Task { [weak self] in
            await self?.capture.cancel()
            try? await Task.sleep(for: .milliseconds(900))
            await MainActor.run {
                self?.resetButtons()
            }
        }
    }

    private func persistIfNeeded() {
        guard settings.liveTranslateSaveDialogue else { return }
        try? store.save(turns: turns)
    }
}
