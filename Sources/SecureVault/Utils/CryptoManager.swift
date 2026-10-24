import Foundation
import CryptoKit
import Security
import UIKit

private enum VaultKeyPurpose { case vault, camera }

final class VaultCipher {
    private let service: String
    private let account: String
    private let pinBindingEnabled: Bool
    private let lock = NSLock()
    private var cachedKey: SymmetricKey?
    private var pinUnlocked = false
    private var protectionObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?

    init(service: String, account: String, pinBindingEnabled: Bool = false) {
        self.service = service; self.account = account; self.pinBindingEnabled = pinBindingEnabled
        protectionObserver = NotificationCenter.default.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: nil) { [weak self] _ in self?.clearCachedKey() }
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in self?.clearCachedKey() }
    }
    deinit {
        if let protectionObserver { NotificationCenter.default.removeObserver(protectionObserver) }
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
    }
    private func clearCachedKey() { lock.lock(); defer { lock.unlock() }; cachedKey = nil; pinUnlocked = false }
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }
    private var pinQuery: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account + ".pin"] }
    private struct PINEnvelope: Codable { let salt: Data; let wrappedKey: Data }
    private func readPINEnvelope() throws -> PINEnvelope? {
        var request = pinQuery; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let envelope = try? JSONDecoder().decode(PINEnvelope.self, from: data) else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return envelope
    }
    private func writePINEnvelope(_ envelope: PINEnvelope) throws {
        let data = try JSONEncoder().encode(envelope); let update: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(pinQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound { var insert = pinQuery; insert[kSecValueData as String] = data; insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly; let added = SecItemAdd(insert as CFDictionary, nil); guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) } }
        else if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    private func pinWrappingKey(_ pin: String, salt: Data) -> SymmetricKey { HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(pin.utf8)), salt: salt, info: Data("SecureVault PIN binding".utf8), outputByteCount: 32) }
    private func key(create: Bool) throws -> SymmetricKey? {
        guard UIApplication.shared.isProtectedDataAvailable else { cachedKey = nil; throw CocoaError(.fileReadNoPermission) }
        if let cachedKey { return cachedKey }
        var lookup = query; lookup[kSecReturnData as String] = true; lookup[kSecReturnAttributes as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?; let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess {
            guard let attributes = result as? [String: Any], let data = attributes[kSecValueData as String] as? Data, data.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
            if (attributes[kSecAttrAccessible as String] as? String) != (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String) { let updated = SecItemUpdate(query as CFDictionary, [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as CFDictionary); guard updated == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(updated)) } }
            if pinBindingEnabled { guard pinUnlocked || (try readPINEnvelope() == nil) else { throw CocoaError(.fileReadNoPermission) } }
            let value = SymmetricKey(data: data); cachedKey = value; return value
        }
        guard status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        guard create else { return nil }
        let value = SymmetricKey(size: .bits256); var insert = query; insert[kSecValueData as String] = value.withUnsafeBytes { Data($0) }; insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(insert as CFDictionary, nil); guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        cachedKey = value; pinUnlocked = !pinBindingEnabled; return value
    }
    func encrypt(_ data: Data) throws -> Data { lock.lock(); defer { lock.unlock() }; guard let key = try key(create: true), let sealed = try AES.GCM.seal(data, using: key).combined else { throw CocoaError(.fileWriteUnknown) }; return sealed }
    func decrypt(_ data: Data) throws -> Data { lock.lock(); defer { lock.unlock() }; guard let key = try key(create: false) else { throw CocoaError(.fileReadNoPermission) }; return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key) }
    func bindPIN(_ pin: String) throws {
        guard pinBindingEnabled else { return }; lock.lock(); defer { lock.unlock() }
        guard pin.count >= 4, let current = try key(create: false) else { throw CocoaError(.fileReadNoPermission) }
        try bindPINUnlocked(pin, current: current)
    }
    private func bindPINUnlocked(_ pin: String, current: SymmetricKey) throws {
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) }); let wrapping = pinWrappingKey(pin, salt: salt)
        guard let wrapped = try AES.GCM.seal(current.withUnsafeBytes { Data($0) }, using: wrapping).combined else { throw CocoaError(.fileWriteUnknown) }
        try writePINEnvelope(PINEnvelope(salt: salt, wrappedKey: wrapped)); let deleted = SecItemDelete(query as CFDictionary); guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(deleted)) }; cachedKey = current; pinUnlocked = true
    }
    func unlock(withPIN pin: String) throws {
        guard pinBindingEnabled else { return }; lock.lock(); defer { lock.unlock() }
        guard UIApplication.shared.isProtectedDataAvailable else { throw CocoaError(.fileReadNoPermission) }
        guard let envelope = try readPINEnvelope() else { guard let current = try key(create: false) else { throw CocoaError(.fileReadNoPermission) }; try bindPINUnlocked(pin, current: current); return }
        let raw = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.wrappedKey), using: pinWrappingKey(pin, salt: envelope.salt)); guard raw.count == 32 else { throw CocoaError(.fileReadCorruptFile) }; cachedKey = SymmetricKey(data: raw); pinUnlocked = true
    }
    func destroyKey() throws {
        lock.lock(); defer { lock.unlock() }; cachedKey = nil; pinUnlocked = false
        let status = SecItemDelete(query as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        if pinBindingEnabled { let pinStatus = SecItemDelete(pinQuery as CFDictionary); guard pinStatus == errSecSuccess || pinStatus == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(pinStatus)) } }
    }
}

enum CryptoManager {
    private static let vaultCipher = VaultCipher(service: "com.securevault.encryption", account: "vaultMasterKey", pinBindingEnabled: true)
    private static let cameraCipher = VaultCipher(service: "com.securevault.encryption", account: "cameraCaptureKey")
    private static let magic = Data([0x53, 0x56, 0x32, 0x01])
    private static func envelope(_ purpose: VaultKeyPurpose, _ payload: Data) -> Data {
        var result = magic
        result.append(purpose == .vault ? 0 : 1)
        result.append(payload)
        return result
    }
    private static func unwrap(_ data: Data) -> (VaultKeyPurpose, Data)? {
        guard data.count > magic.count + 1, Data(data.prefix(magic.count)) == magic else { return nil }
        return (data[magic.count] == 0 ? .vault : .camera, Data(data.dropFirst(magic.count + 1)))
    }
    static func encrypt(_ data: Data) -> Data? { try? VaultGate.shared.withAccess { envelope(.vault, try vaultCipher.encrypt(data)) } }
    static func encryptForCamera(_ data: Data) -> Data? { try? VaultGate.shared.withAccess { envelope(.camera, try cameraCipher.encrypt(data)) } }
    static func decrypt(_ data: Data) -> Data? {
        try? VaultGate.shared.withAccess {
            if let (purpose, payload) = unwrap(data) {
                let cipher = purpose == .vault ? vaultCipher : cameraCipher
                return try cipher.decrypt(payload)
            }
            if let value = try? vaultCipher.decrypt(data) { return value }
            return try cameraCipher.decrypt(data)
        }
    }
    static func bindPIN(_ pin: String) throws { try vaultCipher.bindPIN(pin) }
    static func unlock(withPIN pin: String) throws { try vaultCipher.unlock(withPIN: pin) }
    static func rebindPIN(_ pin: String) throws { try vaultCipher.bindPIN(pin) }
    static func destroyKey() throws { try vaultCipher.destroyKey(); try cameraCipher.destroyKey() }
}
