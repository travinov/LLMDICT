import Foundation

enum RealtimeTranslationEvent: Sendable {
    case outputAudio(Data)
    case inputTranscriptDelta(String)
    case outputTranscriptDelta(String)
    case inputLanguage(String)
    case outputDone
    case error(String)
    case ignored
}

struct RealtimeTranslationEventDecoder: Sendable {
    func decode(_ data: Data) -> RealtimeTranslationEvent {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else {
            return .ignored
        }

        if type == "error" {
            let message = ((object["error"] as? [String: Any])?["message"] as? String) ?? "Realtime API вернул ошибку."
            return .error(message)
        }

        if
            type.hasSuffix("output_audio.delta"),
            let delta = object["delta"] as? String
        {
            return .outputAudio(Data(base64Encoded: delta) ?? Data())
        }

        if type.hasSuffix("output_audio.done") || type.hasSuffix("output_transcript.done") || type.hasSuffix("output_audio_transcript.done") || type.hasSuffix("output_text.done") {
            return .outputDone
        }

        if
            type.contains("input"),
            type.contains("transcript"),
            let delta = object["delta"] as? String
        {
            return .inputTranscriptDelta(delta)
        }

        if
            (type.contains("output_transcript") || type.contains("output_audio_transcript") || type.contains("output_text")),
            let delta = object["delta"] as? String
        {
            return .outputTranscriptDelta(delta)
        }

        if let language = object["language"] as? String, type.contains("input") && type.contains("language") {
            return .inputLanguage(language)
        }

        if let language = object["detected_language"] as? String {
            return .inputLanguage(language)
        }

        return .ignored
    }
}
