import OSLog
import CryptoKit
import Foundation
import Security

/// Stores the group secret. Uses the login keychain, which works for a
/// Developer ID app without a provisioning profile.
enum Keychain {
    private static let service = (Bundle.main.bundleIdentifier ?? "com.Amaury.Relay") + ".group"
    static let defaultAccount = "group-key"

    static func loadGroupKey(account: String = defaultAccount) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else {
            if status != errSecItemNotFound { Log.app.error("Keychain read failed: \(status)") }
            return nil
        }
        return SymmetricKey(data: data)
    }

    @discardableResult
    static func saveGroupKey(_ key: SymmetricKey, account: String = defaultAccount) -> Bool {
        let data = key.withUnsafeBytes { Data($0) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrLabel as String] = "Relay — clé du groupe"
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        if status != errSecSuccess { Log.app.error("Keychain write failed: \(status)") }
        return status == errSecSuccess
    }

    static func deleteGroupKey(account: String = defaultAccount) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
