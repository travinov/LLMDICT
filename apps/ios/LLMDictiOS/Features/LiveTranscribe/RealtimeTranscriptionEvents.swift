import Foundation

enum RealtimeTranscriptionEvent: Equatable, Sendable {
    case committed(itemID: String, previousItemID: String?)
    case delta(itemID: String, text: String)
    case completed(itemID: String, transcript: String)
    case error(String)
    case ignored
}

enum RealtimeTranscriptionEventDecoder {
    static func decode(_ data: Data) throws -> RealtimeTranscriptionEvent {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .ignored
        }

        switch json["type"] as? String {
        case "input_audio_buffer.committed":
            guard let itemID = json["item_id"] as? String else { return .ignored }
            return .committed(itemID: itemID, previousItemID: json["previous_item_id"] as? String)

        case "conversation.item.input_audio_transcription.delta":
            guard
                let itemID = json["item_id"] as? String,
                let delta = json["delta"] as? String
            else { return .ignored }
            return .delta(itemID: itemID, text: delta)

        case "conversation.item.input_audio_transcription.completed":
            guard
                let itemID = json["item_id"] as? String,
                let transcript = json["transcript"] as? String
            else { return .ignored }
            return .completed(itemID: itemID, transcript: transcript)

        case "error":
            let error = json["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "OpenAI Realtime вернул неизвестную ошибку."
            return .error(message)

        default:
            return .ignored
        }
    }
}

actor LiveTranscriptAssembler {
    private var order: [String] = []
    private var partialByItem: [String: String] = [:]
    private var completedByItem: [String: String] = [:]

    func noteCommitted(itemID: String, previousItemID: String?) {
        guard order.contains(itemID) == false else { return }

        if let previousItemID, let previousIndex = order.firstIndex(of: previousItemID) {
            order.insert(itemID, at: previousIndex + 1)
        } else {
            order.append(itemID)
        }
    }

    func append(_ text: String, to itemID: String) {
        ensureItemExists(itemID)
        partialByItem[itemID, default: ""] += text
    }

    func complete(itemID: String, transcript: String) {
        ensureItemExists(itemID)
        completedByItem[itemID] = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        partialByItem[itemID] = nil
    }

    func snapshot() -> LiveTranscriptionSnapshot {
        let final = order
            .compactMap { completedByItem[$0] }
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        let partial = order
            .filter { completedByItem[$0] == nil }
            .compactMap { partialByItem[$0] }
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        return LiveTranscriptionSnapshot(finalText: final, partialText: partial)
    }

    func completedCount() -> Int {
        completedByItem.count
    }

    private func ensureItemExists(_ itemID: String) {
        if order.contains(itemID) == false {
            order.append(itemID)
        }
    }
}
