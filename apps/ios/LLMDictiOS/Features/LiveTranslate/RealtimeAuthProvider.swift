import Foundation

enum RealtimeAuth: Sendable {
    case bearer(String)
}

struct RealtimeAuthProvider: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    @MainActor
    func auth(settings: AppSettings) async throws -> RealtimeAuth {
        switch settings.liveTranslateAuthMode {
        case .directAPIKey:
            let key = settings.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.isEmpty == false else {
                throw LiveTranslateError.missingCredentials
            }
            return .bearer(key)

        case .ephemeralEndpoint:
            let endpoint = settings.liveTranslateEphemeralTokenURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard endpoint.isEmpty == false, let url = URL(string: endpoint) else {
                throw LiveTranslateError.missingCredentials
            }

            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) == false {
                throw NSError(domain: "RealtimeAuthProvider", code: http.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "Endpoint ephemeral token вернул HTTP \(http.statusCode)."
                ])
            }

            if
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let token = Self.extractToken(from: json)
            {
                return .bearer(token)
            }

            if let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), token.isEmpty == false {
                return .bearer(token)
            }

            throw LiveTranslateError.missingCredentials
        }
    }

    private static func extractToken(from json: [String: Any]) -> String? {
        if let value = json["value"] as? String {
            return value
        }
        if let clientSecret = json["client_secret"] as? [String: Any], let value = clientSecret["value"] as? String {
            return value
        }
        if let token = json["token"] as? String {
            return token
        }
        return nil
    }
}
