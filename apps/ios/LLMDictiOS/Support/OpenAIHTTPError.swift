import Foundation

enum OpenAIHTTPError: LocalizedError {
    case unauthorized(operation: String)
    case regionalRestriction(operation: String)
    case accessDenied(operation: String, detail: String?)
    case quotaExceeded(operation: String, detail: String?)
    case requestFailed(operation: String, statusCode: Int, detail: String?)

    var errorDescription: String? {
        switch self {
        case let .unauthorized(operation):
            return "OpenAI отклонил API Key при операции «\(operation)» (HTTP 401). Проверьте ключ в настройках."
        case let .regionalRestriction(operation):
            return "OpenAI недоступен из текущего региона при операции «\(operation)» (HTTP 403). Подключите VPN или укажите доступный совместимый Base URL и повторите запрос."
        case let .accessDenied(operation, detail):
            return Self.appending(
                detail,
                to: "API Key или проект не имеет доступа к операции «\(operation)» или выбранной модели (HTTP 403). Проверьте биллинг и разрешения проекта OpenAI."
            )
        case let .quotaExceeded(operation, detail):
            return Self.appending(
                detail,
                to: "OpenAI отклонил операцию «\(operation)» из-за квоты или лимита (HTTP 429). Проверьте баланс и лимиты проекта."
            )
        case let .requestFailed(operation, statusCode, detail):
            return Self.appending(
                detail,
                to: "OpenAI отклонил операцию «\(operation)» (HTTP \(statusCode))."
            )
        }
    }

    static func make(operation: String, statusCode: Int, data: Data) -> OpenAIHTTPError {
        let payload = payload(from: data)
        switch statusCode {
        case 401:
            return .unauthorized(operation: operation)
        case 403 where isRegionalRestriction(code: payload.code, message: payload.message):
            return .regionalRestriction(operation: operation)
        case 403:
            return .accessDenied(operation: operation, detail: safeDetail(payload.message))
        case 429:
            return .quotaExceeded(operation: operation, detail: safeDetail(payload.message))
        default:
            return .requestFailed(
                operation: operation,
                statusCode: statusCode,
                detail: safeDetail(payload.message)
            )
        }
    }

    static func isRegionalRestriction(code: String? = nil, message: String?) -> Bool {
        let normalized = [code, message]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return normalized.contains("unsupported_country_region_territory")
            || normalized.contains("country, region, or territory not supported")
            || normalized.contains("region is not supported")
            || normalized.contains("unsupported region")
    }

    private static func payload(from data: Data) -> (message: String?, code: String?) {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any]
        else {
            return (nil, nil)
        }
        return (error["message"] as? String, error["code"] as? String ?? error["type"] as? String)
    }

    private static func safeDetail(_ value: String?) -> String? {
        guard let value else { return nil }
        let compact = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.isEmpty == false,
              compact.localizedCaseInsensitiveContains("bearer ") == false,
              compact.localizedCaseInsensitiveContains("sk-") == false else {
            return nil
        }
        return String(compact.prefix(240))
    }

    private static func appending(_ detail: String?, to message: String) -> String {
        guard let detail else { return message }
        return "\(message) Детали OpenAI: \(detail)"
    }
}
