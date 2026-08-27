import XCTest
import SwiftData
@testable import LLMDictiOS

final class AppControllerProcessingTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaultsSuiteName = "AppControllerProcessingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
    }

    @MainActor
    func testRecognizeSavesRawClearsProcessedAndSkipsFormatting() async throws {
        let transcriber = RecordingTranscriptionService(result: .success("new raw"))
        let formatter = RecordingTextProcessingService(result: .success("formatted"))
        let (controller, recording) = try makeController(
            transcriber: transcriber,
            textProcessor: formatter,
            recording: RecordingItem(
                title: "Item",
                filePath: "/tmp/item.wav",
                status: .imported,
                transcriptPreview: "old preview",
                rawTranscript: "old raw",
                processedTranscript: "old processed"
            )
        )

        await controller.recognize(recording)

        XCTAssertEqual(recording.status, RecordingStatus.transcribed)
        XCTAssertEqual(recording.rawTranscript, "new raw")
        XCTAssertNil(recording.processedTranscript)
        XCTAssertEqual(recording.transcriptPreview, "new raw")
        let transcriberCallCount = await transcriber.callCount
        let formatterCallCount = await formatter.callCount
        XCTAssertEqual(transcriberCallCount, 1)
        XCTAssertEqual(formatterCallCount, 0)
    }

    @MainActor
    func testRecognizeErrorKeepsPreviousRawAndProcessed() async throws {
        let transcriber = RecordingTranscriptionService(result: .failure(TestError.sample))
        let formatter = RecordingTextProcessingService(result: .success("formatted"))
        let (controller, recording) = try makeController(
            transcriber: transcriber,
            textProcessor: formatter,
            recording: RecordingItem(
                title: "Item",
                filePath: "/tmp/item.wav",
                status: .imported,
                transcriptPreview: "old preview",
                rawTranscript: "old raw",
                processedTranscript: "old processed"
            )
        )

        await controller.recognize(recording)

        XCTAssertEqual(recording.status, RecordingStatus.error)
        XCTAssertEqual(recording.transcriptPreview, "old preview")
        XCTAssertEqual(recording.rawTranscript, "old raw")
        XCTAssertEqual(recording.processedTranscript, "old processed")
        XCTAssertNotNil(recording.lastTranscriptionError)
        XCTAssertNil(recording.lastProcessingError)
        let transcriberCallCount = await transcriber.callCount
        let formatterCallCount = await formatter.callCount
        XCTAssertEqual(transcriberCallCount, 1)
        XCTAssertEqual(formatterCallCount, 0)
    }

    @MainActor
    func testFormatSavesProcessedAndKeepsRaw() async throws {
        let transcriber = RecordingTranscriptionService(result: .success("raw"))
        let formatter = RecordingTextProcessingService(result: .success("processed"))
        let (controller, recording) = try makeController(
            transcriber: transcriber,
            textProcessor: formatter,
            recording: RecordingItem(
                title: "Item",
                filePath: "/tmp/item.wav",
                status: .transcribed,
                transcriptPreview: "preview",
                rawTranscript: "raw",
                processedTranscript: "old processed"
            )
        )
        let prompt = PromptItem(title: "Prompt", content: "Format this")

        await controller.format(recording, promptOverride: .prompt(prompt))

        XCTAssertEqual(recording.status, RecordingStatus.transcribed)
        XCTAssertEqual(recording.rawTranscript, "raw")
        XCTAssertEqual(recording.processedTranscript, "processed")
        XCTAssertEqual(recording.lastProcessingError, nil)
        let transcriberCallCount = await transcriber.callCount
        let formatterCallCount = await formatter.callCount
        XCTAssertEqual(transcriberCallCount, 0)
        XCTAssertEqual(formatterCallCount, 1)
    }

    @MainActor
    func testFormatErrorKeepsRawAndPreviousProcessedAndWritesProcessingError() async throws {
        let transcriber = RecordingTranscriptionService(result: .success("raw"))
        let formatter = RecordingTextProcessingService(result: .failure(TestError.sample))
        let (controller, recording) = try makeController(
            transcriber: transcriber,
            textProcessor: formatter,
            recording: RecordingItem(
                title: "Item",
                filePath: "/tmp/item.wav",
                status: .transcribed,
                transcriptPreview: "preview",
                rawTranscript: "raw",
                processedTranscript: "old processed"
            )
        )
        let prompt = PromptItem(title: "Prompt", content: "Format this")

        await controller.format(recording, promptOverride: .prompt(prompt))

        XCTAssertEqual(recording.status, RecordingStatus.error)
        XCTAssertEqual(recording.rawTranscript, "raw")
        XCTAssertEqual(recording.processedTranscript, "old processed")
        XCTAssertNotNil(recording.lastProcessingError)
        let transcriberCallCount = await transcriber.callCount
        let formatterCallCount = await formatter.callCount
        XCTAssertEqual(transcriberCallCount, 0)
        XCTAssertEqual(formatterCallCount, 1)
    }

    @MainActor
    func testRecognizeIsSingleFlightForProcessingStatus() async throws {
        let transcriber = BlockingTranscriptionService(result: "new raw")
        let formatter = RecordingTextProcessingService(result: .success("formatted"))
        let (controller, recording) = try makeController(
            transcriber: transcriber,
            textProcessor: formatter,
            recording: RecordingItem(
                title: "Item",
                filePath: "/tmp/item.wav",
                status: .imported
            )
        )

        let first = Task { @MainActor in
            await controller.recognize(recording)
        }

        for _ in 0..<100 {
            if recording.status == RecordingStatus.transcribing { break }
            await Task.yield()
        }
        XCTAssertEqual(recording.status, RecordingStatus.transcribing)

        let second = Task { @MainActor in
            await controller.recognize(recording)
        }

        await second.value
        await transcriber.release()
        await first.value

        let transcriberCallCount = await transcriber.callCount
        XCTAssertEqual(transcriberCallCount, 1)
        XCTAssertEqual(recording.status, RecordingStatus.transcribed)
    }

    @MainActor
    func testFormatIsSingleFlightForProcessingStatus() async throws {
        let transcriber = RecordingTranscriptionService(result: .success("raw"))
        let formatter = BlockingTextProcessingService(result: "processed")
        let (controller, recording) = try makeController(
            transcriber: transcriber,
            textProcessor: formatter,
            recording: RecordingItem(
                title: "Item",
                filePath: "/tmp/item.wav",
                status: .transcribed,
                rawTranscript: "raw"
            )
        )
        let prompt = PromptItem(title: "Prompt", content: "Format this")

        let first = Task { @MainActor in
            await controller.format(recording, promptOverride: .prompt(prompt))
        }

        for _ in 0..<100 {
            if recording.status == RecordingStatus.processingText { break }
            await Task.yield()
        }
        XCTAssertEqual(recording.status, RecordingStatus.processingText)

        let second = Task { @MainActor in
            await controller.format(recording, promptOverride: .prompt(prompt))
        }

        await second.value
        await formatter.release()
        await first.value

        let formatterCallCount = await formatter.callCount
        XCTAssertEqual(formatterCallCount, 1)
        XCTAssertEqual(recording.status, RecordingStatus.transcribed)
    }

    @MainActor
    private func makeController(
        transcriber: any TranscriptionServicing,
        textProcessor: any TextProcessingServicing,
        recording: RecordingItem
    ) throws -> (AppController, RecordingItem) {
        let schema = Schema([RecordingItem.self, PromptItem.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        context.insert(recording)
        let controller = AppController(
            modelContext: context,
            transcriber: transcriber,
            textProcessor: textProcessor
        )
        return (controller, recording)
    }
}

private enum TestError: LocalizedError {
    case sample

    var errorDescription: String? {
        "sample failure"
    }
}

private actor RecordingTranscriptionService: TranscriptionServicing {
    private let result: Result<String, Error>
    private(set) var callCount = 0

    init(result: Result<String, Error>) {
        self.result = result
    }

    func transcribe(recordingURL _: URL, settings _: SettingsSnapshot) async throws -> String {
        callCount += 1
        return try result.get()
    }
}

private actor RecordingTextProcessingService: TextProcessingServicing {
    private let result: Result<String, Error>
    private(set) var callCount = 0

    init(result: Result<String, Error>) {
        self.result = result
    }

    func process(rawTranscript _: String, prompt _: String, settings _: SettingsSnapshot) async throws -> String {
        callCount += 1
        return try result.get()
    }
}

private actor BlockingTranscriptionService: TranscriptionServicing {
    private let result: String
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    init(result: String) {
        self.result = result
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func transcribe(recordingURL _: URL, settings _: SettingsSnapshot) async throws -> String {
        callCount += 1
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return result
    }
}

private actor BlockingTextProcessingService: TextProcessingServicing {
    private let result: String
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    init(result: String) {
        self.result = result
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func process(rawTranscript _: String, prompt _: String, settings _: SettingsSnapshot) async throws -> String {
        callCount += 1
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return result
    }
}
