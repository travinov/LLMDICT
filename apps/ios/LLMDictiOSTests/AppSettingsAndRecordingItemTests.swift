import XCTest
import SwiftData
@testable import LLMDictiOS

final class AppSettingsAndRecordingItemTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaultsSuiteName = "LLMDictiOSTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
    }

    func testTranscriptionProviderTitlesExposeExactModelIDs() {
        XCTAssertEqual(TranscriptionProvider.openAITranscribe.title, "gpt-4o-transcribe")
        XCTAssertEqual(TranscriptionProvider.openAITranscribeMini.title, "gpt-4o-mini-transcribe")
        XCTAssertEqual(TranscriptionProvider.sberSalute.title, "SaluteSpeech")
    }

    @MainActor
    func testAudioEnhancementSettingsDefaultAndPersistence() throws {
        let store = InMemoryCredentialStore()
        let settings = AppSettings(defaults: defaults, credentialStore: store)

        XCTAssertEqual(settings.audioDenoiseStrength, 0.5)
        XCTAssertTrue(settings.useEnhancedAudio)

        settings.audioDenoiseStrength = 0.83
        settings.useEnhancedAudio = false

        let reloaded = AppSettings(defaults: defaults, credentialStore: store)
        XCTAssertEqual(reloaded.audioDenoiseStrength, 0.83)
        XCTAssertFalse(reloaded.useEnhancedAudio)
    }

    @MainActor
    func testLegacyCredentialsMigrateIntoInjectedStoreAndClearLegacyDefaultsAfterSuccessfulWrite() throws {
        defaults.set("  openai-legacy  ", forKey: "openai_api_key")
        defaults.set(" sber-legacy ", forKey: "sber_auth_key")
        defaults.set(" gigachat-legacy ", forKey: "gigachat_auth_key")

        let store = InMemoryCredentialStore()
        let settings = AppSettings(defaults: defaults, credentialStore: store)

        XCTAssertEqual(settings.openAIAPIKey, "openai-legacy")
        XCTAssertEqual(settings.sberAuthKey, "sber-legacy")
        XCTAssertEqual(settings.gigaChatAuthKey, "gigachat-legacy")
        XCTAssertNil(settings.credentialStorageError)

        XCTAssertEqual(store.credentials[.openAI], "openai-legacy")
        XCTAssertEqual(store.credentials[.sberSpeech], "sber-legacy")
        XCTAssertEqual(store.credentials[.gigaChat], "gigachat-legacy")
        XCTAssertNil(defaults.object(forKey: "openai_api_key"))
        XCTAssertNil(defaults.object(forKey: "sber_auth_key"))
        XCTAssertNil(defaults.object(forKey: "gigachat_auth_key"))
    }

    @MainActor
    func testLegacyCredentialsOverrideStoredValuesAndClearLegacyDefaultsAfterSuccessfulMigration() throws {
        let store = InMemoryCredentialStore(initialCredentials: [.openAI: "old-openai"])
        defaults.set(" new-openai ", forKey: "openai_api_key")

        let settings = AppSettings(defaults: defaults, credentialStore: store)

        XCTAssertEqual(settings.openAIAPIKey, "new-openai")
        XCTAssertEqual(store.credentials[.openAI], "new-openai")
        XCTAssertNil(defaults.object(forKey: "openai_api_key"))
        XCTAssertNil(settings.credentialStorageError)
    }

    @MainActor
    func testLegacyCredentialsRemainWhenMigrationToInjectedStoreFails() throws {
        let store = InMemoryCredentialStore(
            initialCredentials: [.openAI: "old-openai"],
            failingKeys: [.openAI]
        )
        defaults.set("new-openai", forKey: "openai_api_key")

        let settings = AppSettings(defaults: defaults, credentialStore: store)

        XCTAssertEqual(settings.openAIAPIKey, "new-openai")
        XCTAssertEqual(store.credentials[.openAI], "old-openai")
        XCTAssertEqual(defaults.string(forKey: "openai_api_key"), "new-openai")
        XCTAssertNotNil(settings.credentialStorageError)
        XCTAssertTrue(settings.credentialStorageError?.contains("Could not migrate the OpenAI API key") == true)
    }

    @MainActor
    func testCredentialWriteFailureKeepsLegacyValueAndReportsStorageError() throws {
        defaults.set("legacy-openai", forKey: "openai_api_key")

        let store = InMemoryCredentialStore(failingKeys: [.openAI])
        let settings = AppSettings(defaults: defaults, credentialStore: store)

        XCTAssertEqual(settings.openAIAPIKey, "legacy-openai")
        XCTAssertEqual(defaults.string(forKey: "openai_api_key"), "legacy-openai")
        XCTAssertEqual(store.credentials[.openAI], nil)
        XCTAssertNotNil(settings.credentialStorageError)
        XCTAssertTrue(settings.credentialStorageError?.contains("Could not migrate the OpenAI API key") == true)
    }

    @MainActor
    func testCredentialUpdatesUseStoreSetAndDeleteWithoutWritingUserDefaults() throws {
        let store = InMemoryCredentialStore()
        let settings = AppSettings(defaults: defaults, credentialStore: store)

        settings.openAIAPIKey = "  next-openai  "
        XCTAssertEqual(settings.openAIAPIKey, "next-openai")
        XCTAssertEqual(store.credentials[.openAI], "next-openai")
        XCTAssertNil(defaults.object(forKey: "openai_api_key"))
        XCTAssertNil(settings.credentialStorageError)

        settings.openAIAPIKey = ""
        XCTAssertNil(store.credentials[.openAI])
        XCTAssertNil(defaults.object(forKey: "openai_api_key"))
        XCTAssertNil(settings.credentialStorageError)
    }

    @MainActor
    func testRecordingItemTranscriptAndErrorResolutionUsesStatusAndPrecedenceRules() throws {
        let errored = RecordingItem(
            title: "Error",
            filePath: "/tmp/error.wav",
            status: .error,
            transcriptPreview: "legacy preview"
        )

        XCTAssertNil(errored.transcriptText)
        XCTAssertFalse(errored.hasTranscript)
        XCTAssertEqual(errored.errorText, "legacy preview")

        let prioritized = RecordingItem(
            title: "Priority",
            filePath: "/tmp/priority.wav",
            status: .transcribed,
            transcriptPreview: "preview",
            rawTranscript: "raw transcript",
            processedTranscript: "processed transcript"
        )

        XCTAssertEqual(prioritized.transcriptText, "processed transcript")
        XCTAssertTrue(prioritized.hasTranscript)
        XCTAssertNil(prioritized.errorText)

        let rawOnly = RecordingItem(
            title: "Raw",
            filePath: "/tmp/raw.wav",
            status: .transcribed,
            rawTranscript: "raw transcript"
        )

        XCTAssertEqual(rawOnly.transcriptText, "raw transcript")
        XCTAssertNil(rawOnly.errorText)
    }

    @MainActor
    func testRecordingItemUsesEnhancedSidecarWhenPresent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingItemSidecarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let originalURL = directory.appendingPathComponent("sample.wav")
        try Data([0x01, 0x02, 0x03]).write(to: originalURL, options: .atomic)

        let recording = RecordingItem(
            title: "Sample",
            filePath: originalURL.path,
            status: .imported
        )

        XCTAssertEqual(recording.preferredAudioURL, originalURL)
        XCTAssertFalse(recording.hasEnhancedAudio)

        try Data([0x04, 0x05, 0x06]).write(to: recording.enhancedFileURL, options: .atomic)

        XCTAssertTrue(recording.hasEnhancedAudio)
        XCTAssertEqual(recording.preferredAudioURL, recording.enhancedFileURL)
    }

    @MainActor
    func testRecordingItemRebasesStaleSandboxPathIntoCurrentApplicationSupport() throws {
        let fileManager = FileManager.default
        let recordingsDirectory = try XCTUnwrap(
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ).appendingPathComponent("Recordings", isDirectory: true)
        try fileManager.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)

        let filename = "stale-path-\(UUID().uuidString).wav"
        let currentURL = recordingsDirectory.appendingPathComponent(filename)
        let enhancedURL = currentURL.deletingPathExtension().appendingPathExtension("enhanced.wav")
        defer {
            try? fileManager.removeItem(at: currentURL)
            try? fileManager.removeItem(at: enhancedURL)
        }
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: currentURL, options: .atomic)

        let stalePath = "/var/mobile/Containers/Data/Application/OLD-UUID/Library/Application Support/Recordings/\(filename)"
        let recording = RecordingItem(title: "Stale", filePath: stalePath, status: .imported)

        XCTAssertEqual(recording.fileURL, currentURL)
        XCTAssertEqual(recording.enhancedFileURL, enhancedURL)
    }

    @MainActor
    func testRepairRecordingFilePathsPersistsRebasedSandboxPath() throws {
        let fileManager = FileManager.default
        let recordingsDirectory = try XCTUnwrap(
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ).appendingPathComponent("Recordings", isDirectory: true)
        try fileManager.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)

        let filename = "repair-path-\(UUID().uuidString).wav"
        let currentURL = recordingsDirectory.appendingPathComponent(filename)
        defer { try? fileManager.removeItem(at: currentURL) }
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: currentURL, options: .atomic)

        let (controller, context) = try makeController()
        let recording = RecordingItem(
            title: "Repair",
            filePath: "/var/mobile/Containers/Data/Application/OLD-UUID/Library/Application Support/Recordings/\(filename)",
            status: .imported
        )
        context.insert(recording)
        try context.save()

        try controller.repairRecordingFilePaths()

        XCTAssertEqual(recording.filePath, currentURL.path)
        XCTAssertEqual(recording.fileURL, currentURL)
    }

    @MainActor
    func testRecoverInterruptedOperationsMarksProcessingRecordAsErrorAndPreservesTranscriptFields() throws {
        let (controller, context) = try makeController()
        let processing = RecordingItem(
            title: "Processing",
            filePath: "/tmp/processing.wav",
            status: .transcribing,
            transcriptPreview: "preview",
            rawTranscript: "raw",
            processedTranscript: "processed"
        )
        let finished = RecordingItem(
            title: "Finished",
            filePath: "/tmp/finished.wav",
            status: .transcribed,
            transcriptPreview: "done",
            rawTranscript: "raw-done",
            processedTranscript: "processed-done"
        )
        context.insert(processing)
        context.insert(finished)

        try controller.recoverInterruptedOperations()

        XCTAssertEqual(processing.status, .error)
        XCTAssertEqual(processing.transcriptPreview, "preview")
        XCTAssertEqual(processing.rawTranscript, "raw")
        XCTAssertEqual(processing.processedTranscript, "processed")
        XCTAssertEqual(processing.lastTranscriptionError, "Распознавание было прервано при предыдущем запуске. Запустите его повторно.")
        XCTAssertEqual(finished.status, .transcribed)
        XCTAssertEqual(finished.transcriptPreview, "done")
    }

    @MainActor
    func testDeleteProcessingRecordingThrowsAndKeepsRecordInContext() throws {
        let (controller, context) = try makeController()
        let recording = RecordingItem(
            title: "Processing",
            filePath: "/tmp/processing.wav",
            status: .transcribing
        )
        context.insert(recording)

        XCTAssertThrowsError(try controller.delete(recording)) { error in
            XCTAssertEqual(error as? RecordingOperationError, .cannotDeleteWhileProcessing)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecordingItem>()), 1)
        XCTAssertEqual(recording.status, .transcribing)
    }

    @MainActor
    func testEnhanceSkipsRecordingsThatAreAlreadyProcessing() async throws {
        let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("EnhanceWhileProcessing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let sourceURL = workDirectory.appendingPathComponent("processing.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: sourceURL, options: .atomic)

        let (controller, context) = try makeController()
        let recording = RecordingItem(
            title: "Processing",
            filePath: sourceURL.path,
            status: .transcribing
        )
        context.insert(recording)

        await controller.enhance(recording)

        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.enhancedFileURL.path))
        XCTAssertFalse(controller.isEnhancing(recording))
        XCTAssertNil(controller.enhancementReport(for: recording))
        XCTAssertNil(controller.enhancementError(for: recording))
        XCTAssertEqual(recording.status, .transcribing)
    }

    @MainActor
    private func makeController() throws -> (AppController, ModelContext) {
        let schema = Schema([RecordingItem.self, PromptItem.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        return (AppController(modelContext: context), context)
    }
}

private final class InMemoryCredentialStore: CredentialStoring {
    private let failingKeys: Set<CredentialKey>
    private(set) var credentials: [CredentialKey: String] = [:]

    init(initialCredentials: [CredentialKey: String] = [:], failingKeys: Set<CredentialKey> = []) {
        self.credentials = initialCredentials
        self.failingKeys = failingKeys
    }

    init(failingKeys: Set<CredentialKey> = []) {
        self.failingKeys = failingKeys
    }

    func credential(for key: CredentialKey) throws -> String? {
        credentials[key]
    }

    func setCredential(_ credential: String, for key: CredentialKey) throws {
        if failingKeys.contains(key) {
            throw TestError.writeFailed
        }
        credentials[key] = credential
    }

    func deleteCredential(for key: CredentialKey) throws {
        if failingKeys.contains(key) {
            throw TestError.deleteFailed
        }
        credentials.removeValue(forKey: key)
    }

    private enum TestError: LocalizedError {
        case writeFailed
        case deleteFailed

        var errorDescription: String? {
            switch self {
            case .writeFailed:
                return "write failed"
            case .deleteFailed:
                return "delete failed"
            }
        }
    }
}
