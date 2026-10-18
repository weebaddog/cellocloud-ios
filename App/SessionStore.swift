// The signed-in account between launches: username, session token and the unlocked vault key,
// in the iPhone's Keychain (this device only, never in backups). Readable after the first
// unlock so camera backup can run in the background. Signing out deletes it.

import CryptoKit
import Foundation
import Security

struct Session {
    let username: String
    let token: String
    let vault: SymmetricKey
}

enum SessionStore {
    private static let service = "com.cellocloud.session"
    private static let account = "current"

    private struct Stored: Codable {
        let username: String
        let token: String
        let vault: Data
    }

    static func load() -> Session? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let s = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        return Session(username: s.username, token: s.token, vault: SymmetricKey(data: s.vault))
    }

    @discardableResult
    static func save(username: String, token: String, vault: SymmetricKey) -> Session {
        let stored = Stored(username: username, token: token, vault: vault.withUnsafeBytes { Data($0) })
        let data = (try? JSONEncoder().encode(stored)) ?? Data()
        clear()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecValueData as String: data,
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(item as CFDictionary, nil)
        return Session(username: username, token: token, vault: vault)
    }

    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}
