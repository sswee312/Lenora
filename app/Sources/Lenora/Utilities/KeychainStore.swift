import Foundation
import Security

enum KeychainStore {
    private static let service: String = Bundle.main.bundleIdentifier ?? "xyz.agentage.lenora"

    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var insert = query
        insert.merge(attrs) { _, new in new }
        return upsert(
            update: { SecItemUpdate(query as CFDictionary, attrs as CFDictionary) },
            add: { SecItemAdd(insert as CFDictionary, nil) },
            delete: { SecItemDelete(query as CFDictionary) }
        )
    }

    /// An item this build may not modify (an ad-hoc rebuild no longer matches its ACL) is
    /// deleted and added fresh, so saving a new value recovers it.
    static func upsert(update: () -> OSStatus, add: () -> OSStatus, delete: () -> OSStatus) -> Bool {
        let status = update()
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return add() == errSecSuccess
        case errSecInteractionNotAllowed, errSecAuthFailed:
            let deleted = delete()
            guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
                Log.app.error("keychain item could not be replaced update=\(status) delete=\(deleted)")
                return false
            }
            return add() == errSecSuccess
        default:
            Log.app.error("keychain update failed status=\(status)")
            return false
        }
    }

    /// Returns nil only when no usable item exists; any other Keychain failure throws.
    static func read(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainReadError(status: status) }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct KeychainReadError: Error {
    let status: OSStatus
}
