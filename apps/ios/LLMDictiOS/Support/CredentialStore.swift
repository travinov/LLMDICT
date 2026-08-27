import Foundation
import Security

enum CredentialKey: String, CaseIterable, Sendable {
    case openAI = "openai"
    case sberSpeech = "sber_speech"
    case gigaChat = "gigachat"

    var displayName: String {
        switch self {
        case .openAI:
            return "OpenAI API key"
        case .sberSpeech:
            return "Sber Speech authorization key"
        case .gigaChat:
            return "GigaChat authorization key"
        }
    }
}

protocol CredentialStoring {
    func credential(for key: CredentialKey) throws -> String?
    func setCredential(_ credential: String, for key: CredentialKey) throws
    func deleteCredential(for key: CredentialKey) throws
}

enum CredentialStoreError: LocalizedError, Sendable {
    case missingBundleIdentifier
    case invalidCredentialData(CredentialKey)
    case keychainFailure(operation: String, key: CredentialKey, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingBundleIdentifier:
            return "The app bundle identifier is unavailable, so credential storage cannot be scoped safely."
        case .invalidCredentialData(let key):
            return "Keychain returned invalid UTF-8 data for the \(key.displayName)."
        case .keychainFailure(let operation, let key, let status):
            let statusDescription = SecCopyErrorMessageString(status, nil).map { $0 as String }
                ?? "Unknown Keychain error"
            return "Keychain could not \(operation) the \(key.displayName) (OSStatus \(status): \(statusDescription))."
        }
    }
}

struct KeychainCredentialStore: CredentialStoring, Sendable {
    private let service: String?

    init(bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        let normalizedBundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedBundleIdentifier, normalizedBundleIdentifier.isEmpty == false {
            self.service = "\(normalizedBundleIdentifier).credentials"
        } else {
            self.service = nil
        }
    }

    func credential(for key: CredentialKey) throws -> String? {
        var query = try baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard
                let data = result as? Data,
                let credential = String(data: data, encoding: .utf8)
            else {
                throw CredentialStoreError.invalidCredentialData(key)
            }
            return credential
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.keychainFailure(operation: "read", key: key, status: status)
        }
    }

    func setCredential(_ credential: String, for key: CredentialKey) throws {
        let query = try baseQuery(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(credential.utf8)
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            switch addStatus {
            case errSecSuccess:
                return
            case errSecDuplicateItem:
                let retryStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                guard retryStatus == errSecSuccess else {
                    throw CredentialStoreError.keychainFailure(operation: "update", key: key, status: retryStatus)
                }
            default:
                throw CredentialStoreError.keychainFailure(operation: "add", key: key, status: addStatus)
            }
        default:
            throw CredentialStoreError.keychainFailure(operation: "update", key: key, status: updateStatus)
        }
    }

    func deleteCredential(for key: CredentialKey) throws {
        let status = SecItemDelete(try baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainFailure(operation: "delete", key: key, status: status)
        }
    }

    private func baseQuery(for key: CredentialKey) throws -> [String: Any] {
        guard let service else {
            throw CredentialStoreError.missingBundleIdentifier
        }

        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
    }
}
