import Foundation
import CryptoKit
import Security
import UIKit

private enum VaultKeyPurpose { case vault, camera }

final class VaultCipher {
    private let service: String
    private let account: String
    private let pinBindingEnabled: Bool
    private let notificationCenter: NotificationCenter
    private let lock = NSLock()
    private var cachedKey: SymmetricKey?
    private var recoveredKeys: [SymmetricKey] = []
    private var pinUnlocked = false
    private var protectionObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?

    init(service: String, account: String, pinBindingEnabled: Bool = false, clearsOnBackground: Bool = true,
         notificationCenter: NotificationCenter = .default) {
        self.service = service; self.account = account; self.pinBindingEnabled = pinBindingEnabled
        self.notificationCenter = notificationCenter
        protectionObserver = notificationCenter.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: nil) { [weak self] _ in self?.clearCachedKey() }
        if clearsOnBackground {
            backgroundObserver = notificationCenter.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in self?.clearCachedKey() }
        }
    }
    deinit {
        if let protectionObserver { notificationCenter.removeObserver(protectionObserver) }
        if let backgroundObserver { notificationCenter.removeObserver(backgroundObserver) }
    }
    private func clearCachedKey() { lock.lock(); defer { lock.unlock() }; cachedKey = nil; recoveredKeys = []; pinUnlocked = false }
    func lockKey() { clearCachedKey() }
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }
    private var pinQuery: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account + ".pin"] }
    private struct PINEnvelope: Codable {
        let salt: Data
        let wrappedKey: Data
        // Optional so envelopes from previous releases decode unchanged.
        var recoveryKeys: [Data]? = nil
    }
    private func readPINEnvelope() throws -> PINEnvelope? {
        var request = pinQuery; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        guard let data = result as? Data, let envelope = try? JSONDecoder().decode(PINEnvelope.self, from: data) else { throw CocoaError(.fileReadCorruptFile) }
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
        guard UIApplication.shared.isProtectedDataAvailable else { cachedKey = nil; recoveredKeys = []; pinUnlocked = false; throw CocoaError(.fileReadNoPermission) }
        if let cachedKey { return cachedKey }
        var lookup = query; lookup[kSecReturnData as String] = true; lookup[kSecReturnAttributes as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?; let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess {
            guard let attributes = result as? [String: Any], let data = attributes[kSecValueData as String] as? Data, data.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
            if (attributes[kSecAttrAccessible as String] as? String) != (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String) { let updated = SecItemUpdate(query as CFDictionary, [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as CFDictionary); guard updated == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(updated)) } }
            if pinBindingEnabled && !pinUnlocked {
                let envelope = try readPINEnvelope()
                guard envelope == nil else { throw CocoaError(.fileReadNoPermission) }
            }
            let value = SymmetricKey(data: data); cachedKey = value; return value
        }
        guard status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        // A missing raw key is the NORMAL state after PIN binding. Never
        // replace that master key when the vault is locked or after a restart.
        if pinBindingEnabled, try readPINEnvelope() != nil { throw CocoaError(.fileReadNoPermission) }
        guard create else { return nil }
        let value = SymmetricKey(size: .bits256); var insert = query; insert[kSecValueData as String] = value.withUnsafeBytes { Data($0) }; insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(insert as CFDictionary, nil); guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        cachedKey = value; pinUnlocked = !pinBindingEnabled; return value
    }
    func encrypt(_ data: Data) throws -> Data { lock.lock(); defer { lock.unlock() }; guard let key = try key(create: true), let sealed = try AES.GCM.seal(data, using: key).combined else { throw CocoaError(.fileWriteUnknown) }; return sealed }
    func decrypt(_ data: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let key = try key(create: false) else { throw CocoaError(.fileReadNoPermission) }
        let box = try AES.GCM.SealedBox(combined: data)
        do { return try AES.GCM.open(box, using: key) }
        catch {
            // Recovery keys are available only after a successful PIN unwrap.
            // They rescue files written by the old accidental-key bug.
            if pinUnlocked {
                for recovered in recoveredKeys {
                    if let value = try? AES.GCM.open(box, using: recovered) { return value }
                }
            }
            throw error
        }
    }
    func bindPIN(_ pin: String) throws {
        guard pinBindingEnabled else { return }; lock.lock(); defer { lock.unlock() }
        guard pin.count >= 4, let current = try key(create: false) else { throw CocoaError(.fileReadNoPermission) }
        try bindPINUnlocked(pin, current: current)
    }
    private func bindPINUnlocked(_ pin: String, current: SymmetricKey) throws {
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) }); let wrapping = pinWrappingKey(pin, salt: salt)
        guard let wrapped = try AES.GCM.seal(current.withUnsafeBytes { Data($0) }, using: wrapping).combined else { throw CocoaError(.fileWriteUnknown) }
        let recovery = try recoveredKeys.map { key -> Data in
            guard let data = try AES.GCM.seal(key.withUnsafeBytes { Data($0) }, using: wrapping).combined else { throw CocoaError(.fileWriteUnknown) }
            return data
        }
        try writePINEnvelope(PINEnvelope(salt: salt, wrappedKey: wrapped, recoveryKeys: recovery.isEmpty ? nil : recovery))
        let deleted = SecItemDelete(query as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(deleted)) }
        cachedKey = current; pinUnlocked = true
    }
    func unlock(withPIN pin: String) throws {
        guard pinBindingEnabled else { return }; lock.lock(); defer { lock.unlock() }
        guard UIApplication.shared.isProtectedDataAvailable else { throw CocoaError(.fileReadNoPermission) }
        guard let envelope = try readPINEnvelope() else { guard let current = try key(create: false) else { throw CocoaError(.fileReadNoPermission) }; try bindPINUnlocked(pin, current: current); return }
        let wrapping = pinWrappingKey(pin, salt: envelope.salt)
        let raw = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.wrappedKey), using: wrapping)
        guard raw.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
        var recoveredData = try (envelope.recoveryKeys ?? []).map { wrapped -> Data in
            let data = try AES.GCM.open(AES.GCM.SealedBox(combined: wrapped), using: wrapping)
            guard data.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
            return data
        }
        // Older builds could create a second raw key beside an existing PIN
        // envelope after backgrounding. Preserve its files, but migrate the
        // key under this correctly entered PIN before deleting the raw item.
        var lookup = query; lookup[kSecReturnData as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess {
            guard let stray = result as? Data, stray.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
            if stray != raw && !recoveredData.contains(stray) {
                recoveredData.append(stray)
                var updated = envelope
                updated.recoveryKeys = try recoveredData.map { data in
                    guard let wrapped = try AES.GCM.seal(data, using: wrapping).combined else { throw CocoaError(.fileWriteUnknown) }
                    return wrapped
                }
                try writePINEnvelope(updated)
            }
            let deleted = SecItemDelete(query as CFDictionary)
            guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(deleted)) }
        } else if status != errSecItemNotFound { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        cachedKey = SymmetricKey(data: raw)
        recoveredKeys = recoveredData.map { SymmetricKey(data: $0) }
        pinUnlocked = true
    }
    func destroyKey() throws {
        lock.lock(); defer { lock.unlock() }; cachedKey = nil; recoveredKeys = []; pinUnlocked = false
        let status = SecItemDelete(query as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        if pinBindingEnabled { let pinStatus = SecItemDelete(pinQuery as CFDictionary); guard pinStatus == errSecSuccess || pinStatus == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(pinStatus)) } }
    }
}

enum CryptoManager {
    // The app owns session locking, including its configurable grace period.
    // Device protected-data lock still always clears the key immediately.
    private static let vaultCipher = VaultCipher(service: "com.securevault.encryption", account: "vaultMasterKey", pinBindingEnabled: true, clearsOnBackground: false)
    private static let cameraCipher = VaultCipher(service: "com.securevault.encryption", account: "cameraCaptureKey")
    private static let magic = Data([0x53, 0x56, 0x32, 0x01])
    private static func envelope(_ purpose: VaultKeyPurpose, _ payload: Data) -> Data {
        var result = magic
        result.append(purpose == .vault ? 0 : 1)
        result.append(contentsOf: payload)
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
    static func lockVault() { vaultCipher.lockKey() }
    static func isCameraEncrypted(_ data: Data) -> Bool {
        guard let (purpose, _) = unwrap(data) else { return false }
        return purpose == .camera
    }
    static func destroyKey() throws { try vaultCipher.destroyKey(); try cameraCipher.destroyKey() }
}
