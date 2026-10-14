import Foundation
import CryptoKit
import Security
import UIKit

// Injectable service/account let tests use a dedicated keychain entry.
final class VaultCipher {
    private let service: String
    private let account: String
    private let lock = NSLock()
    private var cachedKey: SymmetricKey?
    private var protectionObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    init(service: String, account: String) {
        self.service = service
        self.account = account
        protectionObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in self?.clearCachedKey() }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in self?.clearCachedKey() }
    }
    deinit {
        if let protectionObserver { NotificationCenter.default.removeObserver(protectionObserver) }
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
    }
    private func clearCachedKey() {
        lock.lock(); defer { lock.unlock() }
        cachedKey = nil
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    private func key(create: Bool) throws -> SymmetricKey? {
        // A cached key must not bypass the Keychain's WhenUnlocked policy after
        // the device locks, including if a background callback races the notice.
        guard UIApplication.shared.isProtectedDataAvailable else {
            cachedKey = nil
            throw CocoaError(.fileReadNoPermission)
        }
        if let cachedKey = cachedKey { return cachedKey }
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess {
            guard let attributes = result as? [String: Any],
                  let data = attributes[kSecValueData as String] as? Data,
                  data.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
            // Earlier versions used AfterFirstUnlockThisDeviceOnly. Update the
            // existing item in place so old photos retain their original key.
            if (attributes[kSecAttrAccessible as String] as? String) != (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String) {
                let update: [String: Any] = [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
                let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
                guard updated == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(updated)) }
            }
            let value = SymmetricKey(data: data); cachedKey = value; return value
        }
        // Access/entitlement errors must never silently replace an existing key.
        guard status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        guard create else { return nil }
        let value = SymmetricKey(size: .bits256)
        var insert = query
        insert[kSecValueData as String] = value.withUnsafeBytes { Data($0) }
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        cachedKey = value
        return value
    }
    func encrypt(_ data: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let key = try key(create: true), let data = try AES.GCM.seal(data, using: key).combined else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
    func decrypt(_ data: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let key = try key(create: false) else { throw CocoaError(.fileReadNoPermission) }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
    }
    func destroyKey() throws {
        lock.lock(); defer { lock.unlock() }
        cachedKey = nil
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

enum CryptoManager {
    private static let cipher = VaultCipher(service: "com.securevault.encryption", account: "vaultMasterKey")
    static func encrypt(_ data: Data) -> Data? { try? VaultGate.shared.withAccess { try cipher.encrypt(data) } }
    static func decrypt(_ data: Data) -> Data? { try? VaultGate.shared.withAccess { try cipher.decrypt(data) } }
    static func destroyKey() throws { try cipher.destroyKey() }
}
