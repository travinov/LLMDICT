import AVFoundation
import Foundation
import Observation
import UniformTypeIdentifiers
import UIKit

struct RecordedClip {
    let url: URL
    let duration: TimeInterval
}

enum RecorderError: LocalizedError {
    case permissionDenied
    case unavailable
    case noActiveRecording

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Нет доступа к микрофону."
        case .unavailable:
            return "Не удалось подготовить аудиосессию."
        case .noActiveRecording:
            return "Активная запись не найдена."
        }
    }
}

@MainActor
@Observable
final class AudioRecorderService: NSObject, @preconcurrency AVAudioRecorderDelegate {
    private static let meterFloor: Float = -52

    private(set) var isRecording = false
    private(set) var micLevel: Double = 0
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var statusText = "Готов к записи"

    private var recorder: AVAudioRecorder?
    private var meterTask: Task<Void, Never>?
    private var startedAt: Date?

    func setStatus(_ text: String) {
        statusText = text
    }

    func startRecording(audioEnhancement: Bool) async throws {
        guard try await requestPermission() else {
            statusText = "Нет доступа к микрофону"
            throw RecorderError.permissionDenied
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: audioEnhancement ? .voiceChat : .measurement,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            statusText = "Ошибка настройки аудио"
            throw RecorderError.unavailable
        }

        let outputURL = try Self.recordingsDirectory()
            .appendingPathComponent("recording_\(Int(Date().timeIntervalSince1970)).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]

        let recorder = try AVAudioRecorder(url: outputURL, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.delegate = self
        recorder.prepareToRecord()

        guard recorder.record() else {
            statusText = "Не удалось начать запись"
            throw RecorderError.unavailable
        }

        UIApplication.shared.isIdleTimerDisabled = true
        self.recorder = recorder
        startedAt = .now
        elapsedTime = 0
        micLevel = 0
        isRecording = true
        statusText = "Идёт запись"
        startMetering()
    }

    func stopRecording() throws -> RecordedClip {
        guard let recorder else {
            throw RecorderError.noActiveRecording
        }

        recorder.stop()
        meterTask?.cancel()
        meterTask = nil

        let clip = RecordedClip(url: recorder.url, duration: recorder.currentTime)
        self.recorder = nil
        isRecording = false
        statusText = "Запись завершена"
        micLevel = 0
        elapsedTime = 0
        startedAt = nil

        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false)
        return clip
    }

    func cancelRecording() {
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
        meterTask?.cancel()
        meterTask = nil
        isRecording = false
        micLevel = 0
        elapsedTime = 0
        startedAt = nil
        statusText = "Готов к записи"
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        statusText = error?.localizedDescription ?? "Ошибка кодирования аудио"
        cancelRecording()
    }

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while let self, Task.isCancelled == false {
                guard let recorder = self.recorder else { break }
                recorder.updateMeters()
                let averagePower = recorder.averagePower(forChannel: 0)
                let peakPower = recorder.peakPower(forChannel: 0)
                let averageLevel = Self.normalizeDecibels(averagePower)
                let peakLevel = Self.normalizeDecibels(peakPower)
                let blendedLevel = min(1, (averageLevel * 0.68) + (peakLevel * 0.32))
                let previousLevel = self.micLevel
                let smoothedLevel: Double

                if blendedLevel > previousLevel {
                    smoothedLevel = (previousLevel * 0.26) + (blendedLevel * 0.74)
                } else {
                    smoothedLevel = (previousLevel * 0.82) + (blendedLevel * 0.18)
                }

                self.micLevel = smoothedLevel
                if let startedAt = self.startedAt {
                    self.elapsedTime = Date().timeIntervalSince(startedAt)
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private static func normalizeDecibels(_ value: Float) -> Double {
        let clamped = max(value, meterFloor)
        let normalized = (clamped - meterFloor) / abs(meterFloor)
        return Double(max(0, min(1, pow(normalized, 1.35))))
    }

    private func requestPermission() async throws -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    private static func recordingsDirectory() throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@MainActor
@Observable
final class AudioPlayerService: NSObject, @preconcurrency AVAudioPlayerDelegate {
    private(set) var playingFilePath: String?

    private var player: AVAudioPlayer?

    func togglePlayback(url: URL) throws {
        if playingFilePath == url.path {
            stop()
            return
        }

        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.prepareToPlay()
        player.play()
        self.player = player
        playingFilePath = url.path
    }

    func stop() {
        player?.stop()
        player = nil
        playingFilePath = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stop()
    }
}

enum TranscriptionError: LocalizedError {
    case missingAPIKey
    case missingSberKey
    case invalidSberAuthorizationKey
    case unsupportedSberFormat
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Не задан OpenAI API Key."
        case .missingSberKey:
            return "Не задан ключ Sber SaluteSpeech."
        case .invalidSberAuthorizationKey:
            return "Неверный Sber Authorization Key. Нужна Base64-строка из developers.sber.ru, без префиксов Basic/Bearer и не access token."
        case .unsupportedSberFormat:
            return "Для Sber используйте WAV-файлы или записи, созданные внутри приложения."
        case .invalidResponse:
            return "Сервер вернул неожиданный ответ."
        case let .requestFailed(statusCode):
            return "Сервис распознавания вернул ошибку HTTP \(statusCode)."
        }
    }
}

struct MultipartFormDataBuilder {
    let boundary = "Boundary-\(UUID().uuidString)"
    private(set) var data = Data()

    mutating func addTextField(name: String, value: String) {
        data.append("--\(boundary)\r\n")
        data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        data.append("\(value)\r\n")
    }

    mutating func addFileField(name: String, fileURL: URL, mimeType: String) throws {
        let fileData = try Data(contentsOf: fileURL)
        data.append("--\(boundary)\r\n")
        data.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
        data.append("Content-Type: \(mimeType)\r\n\r\n")
        data.append(fileData)
        data.append("\r\n")
    }

    mutating func finalize() -> Data {
        data.append("--\(boundary)--\r\n")
        return data
    }
}

extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}

final class TranscriptionService: TranscriptionServicing {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func transcribe(recordingURL: URL, settings: SettingsSnapshot) async throws -> String {
        switch settings.provider.normalized {
        case .openAITranscribe, .openAIWhisper, .openAIRealtimeWhisper, .openAIGPT4o:
            return try await transcribeWithOpenAIFile(
                recordingURL: recordingURL,
                modelID: "gpt-4o-transcribe",
                settings: settings
            )
        case .openAITranscribeMini:
            return try await transcribeWithOpenAIFile(
                recordingURL: recordingURL,
                modelID: "gpt-4o-mini-transcribe",
                settings: settings
            )
        case .sberSalute:
            return try await transcribeWithSber(recordingURL: recordingURL, settings: settings)
        }
    }

    private func transcribeWithOpenAIFile(
        recordingURL: URL,
        modelID: String,
        settings: SettingsSnapshot
    ) async throws -> String {
        guard settings.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw TranscriptionError.missingAPIKey
        }

        let chunkURLs = try chunkedWaveFilesIfNeeded(sourceURL: recordingURL, maxChunkSize: 20 * 1024 * 1024)
        defer { cleanupTemporaryFiles(chunkURLs, originalURL: recordingURL) }

        var fullText = ""
        for chunkURL in chunkURLs {
            let chunkText = try await sendToOpenAITranscriptions(
                recordingURL: chunkURL,
                modelID: modelID,
                settings: settings
            )
            fullText += chunkText + " "
        }
        let transcript = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard transcript.isEmpty == false else {
            throw TranscriptionError.invalidResponse
        }
        return transcript
    }

    private func transcribeWithSber(recordingURL: URL, settings: SettingsSnapshot) async throws -> String {
        guard settings.sberAuthKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw TranscriptionError.missingSberKey
        }
        guard recordingURL.pathExtension.lowercased() == "wav" else {
            throw TranscriptionError.unsupportedSberFormat
        }

        let speechToken = try await sberToken(authKey: settings.sberAuthKey, scope: "SALUTE_SPEECH_PERS")
        let chunkURLs = try chunkedWaveFilesIfNeeded(sourceURL: recordingURL, maxChunkSize: 900 * 1024)
        defer { cleanupTemporaryFiles(chunkURLs, originalURL: recordingURL) }

        var fullText = ""
        for chunkURL in chunkURLs {
            let text = try await sendToSberSpeech(token: speechToken, fileURL: chunkURL)
            fullText += text + " "
        }

        let transcript = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard transcript.isEmpty == false else {
            throw TranscriptionError.invalidResponse
        }
        return transcript
    }

    private func sendToOpenAITranscriptions(
        recordingURL: URL,
        modelID: String,
        settings: SettingsSnapshot
    ) async throws -> String {
        var builder = MultipartFormDataBuilder()
        try builder.addFileField(
            name: "file",
            fileURL: recordingURL,
            mimeType: mimeType(for: recordingURL)
        )
        builder.addTextField(name: "model", value: modelID)
        builder.addTextField(name: "language", value: "ru")
        builder.addTextField(name: "response_format", value: "json")

        guard let endpoint = URL(string: "\(settings.openAIBaseURL)/audio/transcriptions") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(builder.boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = builder.finalize()

        let (data, response) = try await session.data(for: request)
        try validateOpenAI(response: response, data: data, operation: "распознавание записи")

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = json["text"] as? String
        else {
            throw TranscriptionError.invalidResponse
        }
        return text
    }

    private func sberToken(authKey: String, scope: String) async throws -> String {
        let normalizedKey = try normalizedSberAuthorizationKey(authKey)
        var request = URLRequest(url: URL(string: "https://ngw.devices.sberbank.ru:9443/api/v2/oauth")!)
        request.httpMethod = "POST"
        request.setValue("Basic \(normalizedKey)", forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "RqUID")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "scope=\(scope)".data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        try validateSber(response: response, data: data)

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = json["access_token"] as? String
        else {
            throw TranscriptionError.invalidResponse
        }
        return token
    }

    private func sendToSberSpeech(token: String, fileURL: URL) async throws -> String {
        var request = URLRequest(url: URL(string: "https://smartspeech.sber.ru/rest/v1/speech:recognize")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/x-wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Data(contentsOf: fileURL)

        let (data, response) = try await session.data(for: request)
        try validateSber(response: response, data: data)

        if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return (array.first?["result"] as? String) ?? ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func mimeType(for url: URL) -> String {
        if let utType = UTType(filenameExtension: url.pathExtension) {
            return utType.preferredMIMEType ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }

    private func validateOpenAI(response: URLResponse, data: Data, operation: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard 200 ..< 300 ~= http.statusCode else {
            throw OpenAIHTTPError.make(operation: operation, statusCode: http.statusCode, data: data)
        }
    }

    private func validateSber(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard 200 ..< 300 ~= http.statusCode else {
            let message = String(decoding: data, as: UTF8.self)
            if isSberCredentialMismatch(message) {
                throw TranscriptionError.invalidSberAuthorizationKey
            }
            throw TranscriptionError.requestFailed(http.statusCode)
        }
    }

    private func normalizedSberAuthorizationKey(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw TranscriptionError.missingSberKey
        }

        let withoutScheme: String
        if trimmed.lowercased().hasPrefix("basic ") {
            withoutScheme = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if trimmed.lowercased().hasPrefix("bearer ") {
            withoutScheme = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            withoutScheme = trimmed
        }

        let compact = withoutScheme.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: "")
        let base64Pattern = "^[A-Za-z0-9+/=]+$"
        let looksLikeBase64 = compact.range(of: base64Pattern, options: .regularExpression) != nil

        guard looksLikeBase64, compact.contains(".") == false else {
            throw TranscriptionError.invalidSberAuthorizationKey
        }

        return compact
    }

    private func isSberCredentialMismatch(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("credentials doesn't match db data")
            || normalized.contains("credentials doesnt match db data")
            || normalized.contains("code\":6")
            || normalized.contains("\"code\": 6")
    }

    private func chunkedWaveFilesIfNeeded(sourceURL: URL, maxChunkSize: Int) throws -> [URL] {
        guard sourceURL.pathExtension.lowercased() == "wav" else {
            return [sourceURL]
        }

        let fileSize = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize > maxChunkSize else {
            return [sourceURL]
        }

        let sourceData = try Data(contentsOf: sourceURL)
        guard sourceData.count > 44 else {
            return [sourceURL]
        }

        let header = sourceData.prefix(44)
        let body = sourceData.dropFirst(44)
        let payloadLimit = max(2, maxChunkSize - 44)
        let safeLimit = payloadLimit.isMultiple(of: 2) ? payloadLimit : payloadLimit - 1

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LLMDictChunks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        var chunks: [URL] = []
        var offset = 0
        var index = 0

        while offset < body.count {
            let length = min(safeLimit, body.count - offset)
            let chunkRange = offset ..< (offset + length)
            let chunkBody = body[chunkRange]
            var chunkHeader = Data(header)
            let riffSize = UInt32(length + 36).littleEndian
            let dataSize = UInt32(length).littleEndian
            chunkHeader.replaceSubrange(4 ..< 8, with: withUnsafeBytes(of: riffSize) { Data($0) })
            chunkHeader.replaceSubrange(40 ..< 44, with: withUnsafeBytes(of: dataSize) { Data($0) })

            var chunkData = chunkHeader
            chunkData.append(chunkBody)

            let chunkURL = tempDirectory.appendingPathComponent("chunk_\(index).wav")
            try chunkData.write(to: chunkURL, options: .atomic)
            chunks.append(chunkURL)
            offset += length
            index += 1
        }

        return chunks
    }

    private func cleanupTemporaryFiles(_ urls: [URL], originalURL: URL) {
        for url in urls where url != originalURL {
            try? FileManager.default.removeItem(at: url)
        }

        if let first = urls.first, first != originalURL {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
        }
    }
}
