import Foundation

struct LiveTranslateSessionStore: Sendable {
    func save(turns: [LiveTranslateTurn]) throws {
        let directory = try Self.directory()
        let url = directory.appendingPathComponent("latest_dialogue.json")
        let data = try JSONEncoder.liveTranslate.encode(turns)
        try data.write(to: url, options: [.atomic])
    }

    func load() throws -> [LiveTranslateTurn] {
        let url = try Self.directory().appendingPathComponent("latest_dialogue.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.liveTranslate.decode([LiveTranslateTurn].self, from: data)
    }

    func clear() throws {
        let directory = try Self.directory()
        let dialogueURL = directory.appendingPathComponent("latest_dialogue.json")
        if FileManager.default.fileExists(atPath: dialogueURL.path) {
            try FileManager.default.removeItem(at: dialogueURL)
        }

        let audioDirectory = directory.appendingPathComponent("Audio", isDirectory: true)
        if FileManager.default.fileExists(atPath: audioDirectory.path) {
            try FileManager.default.removeItem(at: audioDirectory)
        }
    }

    func saveTranslatedAudio(_ pcm16: Data, id: UUID, sampleRate: Int = 24_000) throws -> String? {
        guard pcm16.isEmpty == false else { return nil }
        let audioDirectory = try Self.directory().appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let url = audioDirectory.appendingPathComponent("\(id.uuidString).wav")
        try Self.wavData(pcm16: pcm16, sampleRate: sampleRate).write(to: url, options: [.atomic])
        return url.path
    }

    private static func directory() throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("LiveTranslate", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func wavData(pcm16: Data, sampleRate: Int) -> Data {
        let byteRate = sampleRate * 2
        let blockAlign: UInt16 = 2
        let bitsPerSample: UInt16 = 16
        let subchunk2Size = UInt32(pcm16.count)
        let chunkSize = UInt32(36 + pcm16.count)

        var data = Data()
        data.append("RIFF")
        data.append(chunkSize.littleEndianData)
        data.append("WAVE")
        data.append("fmt ")
        data.append(UInt32(16).littleEndianData)
        data.append(UInt16(1).littleEndianData)
        data.append(UInt16(1).littleEndianData)
        data.append(UInt32(sampleRate).littleEndianData)
        data.append(UInt32(byteRate).littleEndianData)
        data.append(blockAlign.littleEndianData)
        data.append(bitsPerSample.littleEndianData)
        data.append("data")
        data.append(subchunk2Size.littleEndianData)
        data.append(pcm16)
        return data
    }
}

private extension FixedWidthInteger {
    var littleEndianData: Data {
        var value = littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

private extension JSONEncoder {
    static var liveTranslate: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var liveTranslate: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
