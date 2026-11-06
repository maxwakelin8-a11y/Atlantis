import Foundation
import Security

/// Stores secrets (API keys, tokens) in the macOS login Keychain. Nothing secret ever goes in
/// files, defaults, logs or the repo (AGENTS.md hard rules).
public struct Keychain: Sendable {
    public enum Failure: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case badData
    }

    /// Keychain "service" that groups this app's items, e.g. "au.lifeos.atlantis".
    public let service: String

    public init(service: String = "au.lifeos.atlantis") {
        self.service = service
    }

    /// Saves or replaces the secret for `account`.
    public func set(_ secret: String, for account: String) throws {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(baseQuery(account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Failure.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw Failure.unexpectedStatus(status)
        }
    }

    /// The secret for `account`, or nil if there isn't one.
    public func get(_ account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.unexpectedStatus(status) }
        guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            throw Failure.badData
        }
        return text
    }

    /// Removes the secret for `account`. Does nothing if there isn't one.
    public func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.unexpectedStatus(status)
        }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: false,
        ]
    }
}
