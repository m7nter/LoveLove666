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
    private var pinUnlocked = false
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
        pinUnlocked = false
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    private var pinQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account + ".pin"]
    }
    private struct PINEnvelope: Codable { let salt: Data; let wrappedKey: Data }
    private func readEnvelope() throws -> PINEnvelope? {
        var request = pinQuery
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let envelope = try? JSONDecoder().decode(PINEnvelope.self, from: data) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return envelope
    }
    private func writeEnvelope(_ envelope: PINEnvelope) throws {
        let data = try JSONEncoder().encode(envelope)
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(pinQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = pinQuery
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        } else if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    private func derivedKey(pin: String, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(pin.utf8)),
                               salt: salt, info: Data("SecureVault PIN binding".utf8), outputByteCount: 32)
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
            guard pinUnlocked || (try readEnvelope() == nil) else { throw CocoaError(.fileReadNoPermission) }
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
        cachedKey = value; pinUnlocked = true
        return value
    }
    func unlock(withPIN pin: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard UIApplication.shared.isProtectedDataAvailable else { throw CocoaError(.fileReadNoPermission) }
        guard let envelope = try readEnvelope() else {
            guard let current = try key(create: false) else { throw CocoaError(.fileReadNoPermission) }
            try storePINBinding(pin, key: current)
            return
        }
        let key = derivedKey(pin: pin, salt: envelope.salt)
        let raw = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.wrappedKey), using: key)
        guard raw.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
        cachedKey = SymmetricKey(data: raw); pinUnlocked = true
    }
    private func storePINBinding(_ pin: String, key current: SymmetricKey) throws {
        guard pin.count >= 4 else { throw CocoaError(.fileWriteUnknown) }
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let wrappingKey = derivedKey(pin: pin, salt: salt)
        guard let wrapped = try AES.GCM.seal(current.withUnsafeBytes { Data($0) }, using: wrappingKey).combined else {
            throw CocoaError(.fileWriteUnknown)
        }
        try writeEnvelope(PINEnvelope(salt: salt, wrappedKey: wrapped))
        let deleted = SecItemDelete(query as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(deleted))
        }
        cachedKey = current; pinUnlocked = true
    }
    func bindPIN(_ pin: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let current = try key(create: false) else { throw CocoaError(.fileReadNoPermission) }
        try storePINBinding(pin, key: current)
    }
    func isPINBound() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (try? readEnvelope()) != nil
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
        pinUnlocked = false
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let pinStatus = SecItemDelete(pinQuery as CFDictionary)
        guard pinStatus == errSecSuccess || pinStatus == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(pinStatus)) }
    }
}

enum CryptoManager {
    private static let cipher = VaultCipher(service: "com.securevault.encryption", account: "vaultMasterKey")
    static func encrypt(_ data: Data) -> Data? { try? VaultGate.shared.withAccess { try cipher.encrypt(data) } }
    static func decrypt(_ data: Data) -> Data? { try? VaultGate.shared.withAccess { try cipher.decrypt(data) } }
    static func unlock(withPIN pin: String) throws { try cipher.unlock(withPIN: pin) }
    static func bindPIN(_ pin: String) throws { try cipher.bindPIN(pin) }
    static func rebindPIN(_ pin: String) throws { try cipher.bindPIN(pin) }
    static var isPINBound: Bool { cipher.isPINBound() }
    static func destroyKey() throws { try cipher.destroyKey() }
}
