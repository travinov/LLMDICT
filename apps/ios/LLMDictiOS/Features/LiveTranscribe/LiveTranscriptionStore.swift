import Foundation

struct LiveTranscriptionStore: Sendable {
    let fileURL: URL

    init(fileManager: FileManager = .default) {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.fileURL = root
            .appendingPathComponent("LiveTranscribe", isDirectory: true)
            .appendingPathComponent("latest_transcript.txt", isDirectory: false)
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    func save(_ transcript: String) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try transcript.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
