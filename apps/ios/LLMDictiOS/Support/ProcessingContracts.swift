import Foundation

protocol TranscriptionServicing: Sendable {
    func transcribe(recordingURL: URL, settings: SettingsSnapshot) async throws -> String
}

protocol TextProcessingServicing: Sendable {
    func process(rawTranscript: String, prompt: String, settings: SettingsSnapshot) async throws -> String
}
