import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    var openAIAPIKey: String {
        didSet {
            handleCredentialChange(
                openAIAPIKey,
                key: .openAI,
                legacyDefaultsKey: Key.openAIAPIKey
            ) { openAIAPIKey = $0 }
        }
    }

    var openAIBaseURL: String {
        didSet {
            let normalized = Self.normalizedBaseURL(openAIBaseURL)
            if normalized != openAIBaseURL {
                openAIBaseURL = normalized
                return
            }
            defaults.set(openAIBaseURL, forKey: Key.openAIBaseURL)
        }
    }

    var sberAuthKey: String {
        didSet {
            handleCredentialChange(
                sberAuthKey,
                key: .sberSpeech,
                legacyDefaultsKey: Key.sberAuthKey
            ) { sberAuthKey = $0 }
        }
    }

    var gigaChatAuthKey: String {
        didSet {
            handleCredentialChange(
                gigaChatAuthKey,
                key: .gigaChat,
                legacyDefaultsKey: Key.gigaChatAuthKey
            ) { gigaChatAuthKey = $0 }
        }
    }

    var credentialStorageError: String?

    var provider: TranscriptionProvider {
        didSet {
            let normalized = provider.normalized
            if normalized != provider {
                provider = normalized
                return
            }
            defaults.set(provider.rawValue, forKey: Key.provider)
        }
    }

    var processingModelProfile: ProcessingModelProfile {
        didSet { defaults.set(processingModelProfile.rawValue, forKey: Key.processingModelProfile) }
    }

    var audioEnhancementEnabled: Bool {
        didSet { defaults.set(audioEnhancementEnabled, forKey: Key.audioEnhancementEnabled) }
    }

    var audioDenoiseStrength: Double {
        didSet {
            let clamped = min(1, max(0, audioDenoiseStrength))
            if clamped != audioDenoiseStrength {
                audioDenoiseStrength = clamped
                return
            }
            defaults.set(audioDenoiseStrength, forKey: Key.audioDenoiseStrength)
        }
    }

    var useEnhancedAudio: Bool {
        didSet { defaults.set(useEnhancedAudio, forKey: Key.useEnhancedAudio) }
    }

    var liveTranscribeLanguageCode: String {
        didSet {
            let normalized = Self.normalizedLiveTranscribeLanguageCode(liveTranscribeLanguageCode)
            if normalized != liveTranscribeLanguageCode {
                liveTranscribeLanguageCode = normalized
                return
            }
            defaults.set(liveTranscribeLanguageCode, forKey: Key.liveTranscribeLanguageCode)
        }
    }

    var liveTranscribeDelay: LiveTranscriptionDelay {
        didSet { defaults.set(liveTranscribeDelay.rawValue, forKey: Key.liveTranscribeDelay) }
    }

    var liveTranslateModel: String {
        didSet { defaults.set(liveTranslateModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.liveTranslateModel) }
    }

    var liveTranslateOwnerLanguageCode: String {
        didSet { defaults.set(liveTranslateOwnerLanguageCode, forKey: Key.liveTranslateOwnerLanguageCode) }
    }

    var liveTranslateOtherLanguageCode: String {
        didSet { defaults.set(liveTranslateOtherLanguageCode, forKey: Key.liveTranslateOtherLanguageCode) }
    }

    var liveTranslateAutoFillDetectedLanguage: Bool {
        didSet { defaults.set(liveTranslateAutoFillDetectedLanguage, forKey: Key.liveTranslateAutoFillDetectedLanguage) }
    }

    var liveTranslateVoice: String {
        didSet { defaults.set(liveTranslateVoice.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.liveTranslateVoice) }
    }

    var liveTranslateAutoSpeak: Bool {
        didSet { defaults.set(liveTranslateAutoSpeak, forKey: Key.liveTranslateAutoSpeak) }
    }

    var liveTranslateMaxTurnDuration: Double {
        didSet { defaults.set(liveTranslateMaxTurnDuration, forKey: Key.liveTranslateMaxTurnDuration) }
    }

    var liveTranslateSaveDialogue: Bool {
        didSet { defaults.set(liveTranslateSaveDialogue, forKey: Key.liveTranslateSaveDialogue) }
    }

    var liveTranslateKeepAudioSnippets: Bool {
        didSet { defaults.set(liveTranslateKeepAudioSnippets, forKey: Key.liveTranslateKeepAudioSnippets) }
    }

    var liveTranslateAuthMode: LiveTranslateAuthMode {
        didSet { defaults.set(liveTranslateAuthMode.rawValue, forKey: Key.liveTranslateAuthMode) }
    }

    var liveTranslateEphemeralTokenURL: String {
        didSet { defaults.set(Self.normalizedOptionalURL(liveTranslateEphemeralTokenURL), forKey: Key.liveTranslateEphemeralTokenURL) }
    }

    private let defaults: UserDefaults
    private let credentialStore: any CredentialStoring
    @ObservationIgnored private var isNormalizingCredential = false

    init(
        defaults: UserDefaults = .standard,
        credentialStore: any CredentialStoring = KeychainCredentialStore()
    ) {
        let openAIAPIKeyResult = Self.loadCredential(
            key: .openAI,
            legacyDefaultsKey: Key.openAIAPIKey,
            defaults: defaults,
            credentialStore: credentialStore
        )
        let sberAuthKeyResult = Self.loadCredential(
            key: .sberSpeech,
            legacyDefaultsKey: Key.sberAuthKey,
            defaults: defaults,
            credentialStore: credentialStore
        )
        let gigaChatAuthKeyResult = Self.loadCredential(
            key: .gigaChat,
            legacyDefaultsKey: Key.gigaChatAuthKey,
            defaults: defaults,
            credentialStore: credentialStore
        )
        let credentialErrors = [
            openAIAPIKeyResult.errorMessage,
            sberAuthKeyResult.errorMessage,
            gigaChatAuthKeyResult.errorMessage
        ].compactMap { $0 }

        self.defaults = defaults
        self.credentialStore = credentialStore
        self.openAIAPIKey = openAIAPIKeyResult.value
        self.openAIBaseURL = Self.normalizedBaseURL(defaults.string(forKey: Key.openAIBaseURL) ?? "https://api.openai.com/v1")
        self.sberAuthKey = sberAuthKeyResult.value
        self.gigaChatAuthKey = gigaChatAuthKeyResult.value
        self.credentialStorageError = credentialErrors.isEmpty ? nil : credentialErrors.joined(separator: "\n")
        let storedProvider = TranscriptionProvider(rawValue: defaults.string(forKey: Key.provider) ?? "")
        self.provider = (storedProvider ?? .openAITranscribe).normalized
        self.processingModelProfile = ProcessingModelProfile(
            rawValue: defaults.string(forKey: Key.processingModelProfile) ?? ""
        ) ?? .gpt56Luna
        self.audioEnhancementEnabled = defaults.bool(forKey: Key.audioEnhancementEnabled)
        self.audioDenoiseStrength = min(
            1,
            max(0, defaults.object(forKey: Key.audioDenoiseStrength) as? Double ?? 0.5)
        )
        self.useEnhancedAudio = defaults.object(forKey: Key.useEnhancedAudio) as? Bool ?? true
        self.liveTranscribeLanguageCode = Self.normalizedLiveTranscribeLanguageCode(
            defaults.string(forKey: Key.liveTranscribeLanguageCode) ?? "ru"
        )
        self.liveTranscribeDelay = LiveTranscriptionDelay(
            rawValue: defaults.string(forKey: Key.liveTranscribeDelay) ?? ""
        ) ?? .low
        self.liveTranslateModel = defaults.string(forKey: Key.liveTranslateModel) ?? "gpt-realtime-translate"
        self.liveTranslateOwnerLanguageCode = defaults.string(forKey: Key.liveTranslateOwnerLanguageCode) ?? "ru"
        self.liveTranslateOtherLanguageCode = defaults.string(forKey: Key.liveTranslateOtherLanguageCode) ?? "auto"
        self.liveTranslateAutoFillDetectedLanguage = defaults.object(forKey: Key.liveTranslateAutoFillDetectedLanguage) as? Bool ?? true
        self.liveTranslateVoice = defaults.string(forKey: Key.liveTranslateVoice) ?? "marin"
        self.liveTranslateAutoSpeak = defaults.object(forKey: Key.liveTranslateAutoSpeak) as? Bool ?? true
        self.liveTranslateMaxTurnDuration = defaults.object(forKey: Key.liveTranslateMaxTurnDuration) as? Double ?? 20
        self.liveTranslateSaveDialogue = defaults.object(forKey: Key.liveTranslateSaveDialogue) as? Bool ?? true
        self.liveTranslateKeepAudioSnippets = defaults.bool(forKey: Key.liveTranslateKeepAudioSnippets)
        self.liveTranslateAuthMode = LiveTranslateAuthMode(rawValue: defaults.string(forKey: Key.liveTranslateAuthMode) ?? "") ?? .directAPIKey
        self.liveTranslateEphemeralTokenURL = defaults.string(forKey: Key.liveTranslateEphemeralTokenURL) ?? ""
        defaults.set(provider.rawValue, forKey: Key.provider)
    }

    private func handleCredentialChange(
        _ value: String,
        key: CredentialKey,
        legacyDefaultsKey: String,
        assignNormalizedValue: (String) -> Void
    ) {
        guard isNormalizingCredential == false else { return }

        let normalizedValue = Self.normalizedCredential(value)
        if normalizedValue != value {
            isNormalizingCredential = true
            assignNormalizedValue(normalizedValue)
            isNormalizingCredential = false
        }

        do {
            try Self.persistCredential(normalizedValue, key: key, credentialStore: credentialStore)
            defaults.removeObject(forKey: legacyDefaultsKey)
            credentialStorageError = nil
        } catch {
            credentialStorageError = Self.credentialErrorMessage(error, key: key, operation: "save")
        }
    }

    private static func loadCredential(
        key: CredentialKey,
        legacyDefaultsKey: String,
        defaults: UserDefaults,
        credentialStore: any CredentialStoring
    ) -> CredentialLoadResult {
        let legacyValue = defaults.string(forKey: legacyDefaultsKey).map(normalizedCredential)
        let hasLegacyValue = defaults.object(forKey: legacyDefaultsKey) != nil

        let storedCredential: String?
        do {
            storedCredential = try credentialStore.credential(for: key)
        } catch {
            return CredentialLoadResult(
                value: legacyValue ?? "",
                errorMessage: credentialErrorMessage(error, key: key, operation: "read")
            )
        }

        if let storedCredential {
            let normalizedStoredCredential = normalizedCredential(storedCredential)

            guard hasLegacyValue else {
                guard normalizedStoredCredential != storedCredential else {
                    return CredentialLoadResult(value: normalizedStoredCredential, errorMessage: nil)
                }

                do {
                    try persistCredential(normalizedStoredCredential, key: key, credentialStore: credentialStore)
                    return CredentialLoadResult(value: normalizedStoredCredential, errorMessage: nil)
                } catch {
                    return CredentialLoadResult(
                        value: normalizedStoredCredential,
                        errorMessage: credentialErrorMessage(error, key: key, operation: "normalize")
                    )
                }
            }

            guard let legacyValue else {
                defaults.removeObject(forKey: legacyDefaultsKey)
                return CredentialLoadResult(value: normalizedStoredCredential, errorMessage: nil)
            }

            guard legacyValue != normalizedStoredCredential else {
                defaults.removeObject(forKey: legacyDefaultsKey)
                return CredentialLoadResult(value: legacyValue, errorMessage: nil)
            }

            do {
                try persistCredential(legacyValue, key: key, credentialStore: credentialStore)
                defaults.removeObject(forKey: legacyDefaultsKey)
                return CredentialLoadResult(value: legacyValue, errorMessage: nil)
            } catch {
                return CredentialLoadResult(
                    value: legacyValue,
                    errorMessage: credentialErrorMessage(error, key: key, operation: "migrate")
                )
            }
        }

        guard let legacyValue else {
            return CredentialLoadResult(value: "", errorMessage: nil)
        }

        do {
            try persistCredential(legacyValue, key: key, credentialStore: credentialStore)
            defaults.removeObject(forKey: legacyDefaultsKey)
            return CredentialLoadResult(value: legacyValue, errorMessage: nil)
        } catch {
            return CredentialLoadResult(
                value: legacyValue,
                errorMessage: credentialErrorMessage(error, key: key, operation: "migrate")
            )
        }
    }

    private static func persistCredential(
        _ value: String,
        key: CredentialKey,
        credentialStore: any CredentialStoring
    ) throws {
        if value.isEmpty {
            try credentialStore.deleteCredential(for: key)
        } else {
            try credentialStore.setCredential(value, for: key)
        }
    }

    private static func credentialErrorMessage(
        _: Error,
        key: CredentialKey,
        operation: String
    ) -> String {
        "Could not \(operation) the \(key.displayName)."
    }

    private enum Key {
        static let openAIAPIKey = "openai_api_key"
        static let openAIBaseURL = "openai_base_url"
        static let sberAuthKey = "sber_auth_key"
        static let gigaChatAuthKey = "gigachat_auth_key"
        static let provider = "transcription_provider"
        static let processingModelProfile = "processing_model_profile"
        static let audioEnhancementEnabled = "audio_enhancement_enabled"
        static let audioDenoiseStrength = "audio_denoise_strength"
        static let useEnhancedAudio = "use_enhanced_audio"
        static let liveTranscribeLanguageCode = "live_transcribe_language_code"
        static let liveTranscribeDelay = "live_transcribe_delay"
        static let liveTranslateModel = "live_translate_model"
        static let liveTranslateOwnerLanguageCode = "live_translate_owner_language_code"
        static let liveTranslateOtherLanguageCode = "live_translate_other_language_code"
        static let liveTranslateAutoFillDetectedLanguage = "live_translate_auto_fill_detected_language"
        static let liveTranslateVoice = "live_translate_voice"
        static let liveTranslateAutoSpeak = "live_translate_auto_speak"
        static let liveTranslateMaxTurnDuration = "live_translate_max_turn_duration"
        static let liveTranslateSaveDialogue = "live_translate_save_dialogue"
        static let liveTranslateKeepAudioSnippets = "live_translate_keep_audio_snippets"
        static let liveTranslateAuthMode = "live_translate_auth_mode"
        static let liveTranslateEphemeralTokenURL = "live_translate_ephemeral_token_url"
    }

    private static func normalizedBaseURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "https://api.openai.com/v1"
        }
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    private static func normalizedOptionalURL(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedCredential(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedLiveTranscribeLanguageCode(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if LiveTranslateLanguage.supported.contains(where: { $0.id == normalized }) {
            return normalized
        }

        if let language = normalized.split(separator: "-").first.map(String.init),
           LiveTranslateLanguage.supported.contains(where: { $0.id == language }) {
            return language
        }

        return "ru"
    }

    private struct CredentialLoadResult {
        let value: String
        let errorMessage: String?
    }
}

struct SettingsSnapshot: Sendable {
    let openAIAPIKey: String
    let openAIBaseURL: String
    let sberAuthKey: String
    let gigaChatAuthKey: String
    let provider: TranscriptionProvider
    let processingModelProfile: ProcessingModelProfile
    let audioEnhancementEnabled: Bool
    let audioDenoiseStrength: Double
    let useEnhancedAudio: Bool

    @MainActor
    init(settings: AppSettings) {
        self.openAIAPIKey = settings.openAIAPIKey
        self.openAIBaseURL = settings.openAIBaseURL
        self.sberAuthKey = settings.sberAuthKey
        self.gigaChatAuthKey = settings.gigaChatAuthKey
        self.provider = settings.provider
        self.processingModelProfile = settings.processingModelProfile
        self.audioEnhancementEnabled = settings.audioEnhancementEnabled
        self.audioDenoiseStrength = settings.audioDenoiseStrength
        self.useEnhancedAudio = settings.useEnhancedAudio
    }
}
