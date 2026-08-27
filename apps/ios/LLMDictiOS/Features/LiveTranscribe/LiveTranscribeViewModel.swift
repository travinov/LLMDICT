import Foundation
import Observation

@MainActor
@Observable
final class LiveTranscribeViewModel {
    private(set) var state: LiveTranscriptionState = .idle
    private(set) var finalTranscript: String
    private(set) var partialTranscript = ""
    private(set) var micLevel: Double = 0
    var errorMessage: String?

    var settings: AppSettings

    @ObservationIgnored private let capture: LiveAudioCaptureService
    @ObservationIgnored private let client: any RealtimeTranscriptionClientProtocol
    @ObservationIgnored private let authProvider: RealtimeAuthProvider
    @ObservationIgnored private let store: LiveTranscriptionStore
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var startGeneration: UInt = 0

    init(
        settings: AppSettings,
        capture: LiveAudioCaptureService = LiveAudioCaptureService(),
        client: any RealtimeTranscriptionClientProtocol = RealtimeTranscriptionClient(),
        authProvider: RealtimeAuthProvider = RealtimeAuthProvider(),
        store: LiveTranscriptionStore = LiveTranscriptionStore()
    ) {
        self.settings = settings
        self.capture = capture
        self.client = client
        self.authProvider = authProvider
        self.store = store
        self.finalTranscript = store.load()
    }

    var displayedTranscript: String {
        [finalTranscript, partialTranscript]
            .filter { $0.isEmpty == false }
            .joined(separator: finalTranscript.isEmpty || partialTranscript.isEmpty ? "" : " ")
    }

    func start() async {
        guard state == .idle else { return }
        startGeneration &+= 1
        let generation = startGeneration
        errorMessage = nil
        partialTranscript = ""
        state = .connecting

        do {
            let auth = try await authProvider.auth(settings: settings)
            guard generation == startGeneration, state == .connecting else { return }
            let stream = try await capture.start(maxDuration: 30 * 60)
            guard generation == startGeneration, state == .connecting else {
                await capture.cancel()
                return
            }
            let language = LiveTranslateLanguage.language(for: settings.liveTranscribeLanguageCode)
            let configuration = RealtimeTranscriptionConfiguration(
                baseURL: settings.openAIBaseURL,
                auth: auth,
                languageCode: language.openAICode,
                delay: settings.liveTranscribeDelay
            )

            state = .recording
            startMeter()
            transcriptionTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let transcript = try await self.client.transcribe(
                        audioChunks: stream,
                        configuration: configuration
                    ) { [weak self] snapshot in
                        await MainActor.run {
                            self?.finalTranscript = snapshot.finalText
                            self?.partialTranscript = snapshot.partialText
                        }
                    }
                    self.finalTranscript = transcript
                    self.partialTranscript = ""
                    try self.store.save(transcript)
                    self.finishNormally()
                } catch is CancellationError {
                    self.finishNormally()
                } catch {
                    await self.capture.cancel()
                    self.fail(error)
                }
            }
        } catch {
            guard generation == startGeneration else { return }
            await capture.cancel()
            fail(error)
        }
    }

    func stop() async {
        guard state == .recording || state == .connecting else { return }
        state = .finishing
        meterTask?.cancel()
        meterTask = nil
        micLevel = 0
        await capture.stop()
    }

    func cancel() async {
        startGeneration &+= 1
        transcriptionTask?.cancel()
        transcriptionTask = nil
        meterTask?.cancel()
        meterTask = nil
        await capture.cancel()
        micLevel = 0
        state = .idle
    }

    func clear() {
        guard state == .idle else { return }
        finalTranscript = ""
        partialTranscript = ""
        do {
            try store.clear()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startMeter() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while Task.isCancelled == false {
                guard let self else { return }
                self.micLevel = self.capture.micLevel
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func finishNormally() {
        meterTask?.cancel()
        meterTask = nil
        transcriptionTask = nil
        micLevel = 0
        state = .idle
    }

    private func fail(_ error: any Error) {
        meterTask?.cancel()
        meterTask = nil
        transcriptionTask = nil
        micLevel = 0
        state = .idle
        errorMessage = error.localizedDescription
    }
}
