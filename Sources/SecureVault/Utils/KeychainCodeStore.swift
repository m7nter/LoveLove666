import Foundation
import Security

// Access codes must not be readable from the application's preferences file.
// The first read imports codes from earlier versions without changing them.
enum KeychainCodeStore {
    private static let service = "com.securevault.accesscodes"
    private static let accounts = ["mainCode", "vaultCode", "kamikazeCode", "actionButtonToken"]

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(_ account: String, legacyDefault: String = "",
                     accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly) -> String {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else { return "" }
            return value
        }
        // Other Keychain errors must never turn into the known legacy default.
        guard status == errSecItemNotFound else { return "" }
        let value = UserDefaults.standard.string(forKey: account) ?? legacyDefault
        guard !value.isEmpty else { return "" }
        do { try write(value, for: account, accessible: accessible); return value }
        catch { return "" }
    }

    static func write(_ value: String, for account: String,
                      accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly) throws {
        if value.isEmpty { try delete(account); return }
        let data = Data(value.utf8)
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible
        ]
        let updated = SecItemUpdate(query(account) as CFDictionary, updates as CFDictionary)
        if updated == errSecItemNotFound {
            var insert = query(account)
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = accessible
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        } else if updated != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updated))
        }
        UserDefaults.standard.removeObject(forKey: account)
    }

    static func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        UserDefaults.standard.removeObject(forKey: account)
    }

    static func deleteAll() throws {
        for account in accounts { try delete(account) }
    }

    static func readActionToken() -> String {
        read("actionButtonToken", accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    static func writeActionToken(_ token: String) throws {
        try write(token, for: "actionButtonToken", accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }
}
