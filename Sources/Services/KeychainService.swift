import Foundation
import Security

enum KeychainError: Error, LocalizedError {
    case readFailed(OSStatus)
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case unexpectedData

    var errorDescription: String? {
        switch self {
        case .readFailed(let status):
            "Failed to read from Keychain (status: \(status))."
        case .saveFailed(let status):
            "Failed to save to Keychain (status: \(status))."
        case .deleteFailed(let status):
            "Failed to delete from Keychain (status: \(status))."
        case .unexpectedData:
            "Unexpected Keychain data."
        }
    }
}

protocol KeychainStoring: AnyObject, Sendable {
    var oauthMutationState: GoogleOAuthMutationState { get }
    func save(_ value: String, forKey key: String) throws
    func read(forKey key: String) throws -> String?
    func retrieve(forKey key: String) -> String?
    func delete(forKey key: String) throws
}

extension KeychainStoring {
    var oauthMutationState: GoogleOAuthMutationState {
        GoogleOAuthMutationState.shared(store: self)
    }

    func read(forKey key: String) throws -> String? {
        retrieve(forKey: key)
    }
}

final class KeychainService: KeychainStoring {
    static let shared = KeychainService()

    private let service: String
    let oauthMutationState: GoogleOAuthMutationState

    init(service: String = AppIdentity.keychainServiceName) {
        self.service = service
        self.oauthMutationState = GoogleOAuthMutationState.shared(service: service)
    }

    func save(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.unexpectedData }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.saveFailed(updateStatus) }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.saveFailed(addStatus) }
    }

    func retrieve(forKey key: String) -> String? {
        try? read(forKey: key)
    }

    func read(forKey key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.readFailed(status) }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        return value
    }

    func delete(forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}
