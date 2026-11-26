import Foundation
import Security
import LionCore

/// Secrets (sign-in tokens, cached account data) in the iOS Keychain. Readable after the first unlock since boot,
/// so a background refresh can use them; never synced to iCloud or copied to another phone.
final class KeychainStore: SecretStore, @unchecked Sendable {
    private let service = "lioncar"
    /// `set` is an update, then an add if missing: the lock keeps two callers from both adding the same key.
    private let lock = NSLock()

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ key: String, _ value: String?) {
        lock.lock(); defer { lock.unlock() }
        let q = query(key)
        guard let value else { SecItemDelete(q as CFDictionary); return }
        let data = Data(value.utf8)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(q as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = q
            add.merge(attrs) { $1 }
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
