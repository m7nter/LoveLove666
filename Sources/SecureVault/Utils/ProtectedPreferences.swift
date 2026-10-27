import Foundation

/// Stores small sensitive preferences as CryptoKit ciphertext rather than as
/// readable values in the application's preferences plist. Values written by
/// older releases are migrated opportunistically and removed only after the
/// encrypted copy has been saved successfully.
struct ProtectedPreferenceStore {
    private let prefix = "protected."
    private let defaults: UserDefaults
    private let encryptVault: (Data) -> Data?
    private let encryptCamera: (Data) -> Data?
    private let decrypt: (Data) -> Data?
    private let isCameraEncrypted: (Data) -> Bool

    // These settings are also required by the intentionally restricted Action
    // Button camera, which never unlocks the PIN-bound vault master key.
    private let cameraKeys: Set<String> = [
        "pendingCaptureEvent", "labelTemplates", "selectedTemplate", "userAvatar"
    ]

    init(defaults: UserDefaults = .standard,
         encryptVault: @escaping (Data) -> Data? = CryptoManager.encrypt,
         encryptCamera: @escaping (Data) -> Data? = CryptoManager.encryptForCamera,
         decrypt: @escaping (Data) -> Data? = CryptoManager.decrypt,
         isCameraEncrypted: @escaping (Data) -> Bool = CryptoManager.isCameraEncrypted) {
        self.defaults = defaults
        self.encryptVault = encryptVault
        self.encryptCamera = encryptCamera
        self.decrypt = decrypt
        self.isCameraEncrypted = isCameraEncrypted
    }

    // Keys are deliberately kept in one place so a destructive reset cannot
    // leave encrypted preference blobs behind after the vault key is removed.
    private let sensitiveKeys = [
        "calculator.history.v2", "pendingCaptureEvent", "labelTemplates",
        "selectedTemplate", "userAvatar"
    ]

    private func protectedKey(for key: String) -> String { prefix + key }

    private func encrypt(_ value: Data, forKey key: String) -> Data? {
        cameraKeys.contains(key) ? encryptCamera(value) : encryptVault(value)
    }

    func data(forKey key: String) -> Data? {
        let encryptedKey = protectedKey(for: key)
        if let encrypted = defaults.data(forKey: encryptedKey) {
            // A locked vault is not an absent preference. Leave the ciphertext
            // untouched until a successful PIN unlock makes migration possible.
            guard let value = decrypt(encrypted) else { return nil }
            if cameraKeys.contains(key), !isCameraEncrypted(encrypted) {
                migrate(value, forKey: key)
            }
            return value
        }
        guard let legacy = defaults.data(forKey: key) else { return nil }
        migrate(legacy, forKey: key)
        return legacy
    }

    @discardableResult func set(_ value: Data?, forKey key: String) -> Bool {
        let encryptedKey = protectedKey(for: key)
        guard let value else {
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: encryptedKey)
            return true
        }
        guard let encrypted = encrypt(value, forKey: key) else {
            // Protected data may be unavailable during a lock transition.
            // Never write the new sensitive value in plaintext as a fallback;
            // the caller can retry after the device is unlocked.
            return false
        }
        defaults.set(encrypted, forKey: encryptedKey)
        defaults.removeObject(forKey: key)
        return true
    }

    func remove(forKey key: String) {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: protectedKey(for: key))
    }

    func removeAll() {
        sensitiveKeys.forEach { remove(forKey: $0) }
        // Remove any future protected entries from a previous version too.
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) }
            .forEach { defaults.removeObject(forKey: $0) }
    }

    func string(forKey key: String) -> String? {
        if let data = data(forKey: key) { return String(data: data, encoding: .utf8) }
        guard let legacy = defaults.string(forKey: key) else { return nil }
        migrate(Data(legacy.utf8), forKey: key)
        return legacy
    }

    @discardableResult func set(_ value: String, forKey key: String) -> Bool { set(Data(value.utf8), forKey: key) }

    func stringArray(forKey key: String) -> [String]? {
        if let data = data(forKey: key) { return try? JSONDecoder().decode([String].self, from: data) }
        let legacy = defaults.stringArray(forKey: key)
        if let legacy { migrate(legacy, forKey: key) }
        return legacy
    }

    @discardableResult func set(_ value: [String], forKey key: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        return set(data, forKey: key)
    }

    private func migrate(_ value: [String], forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        migrate(data, forKey: key)
    }

    private func migrate(_ value: Data, forKey key: String) {
        guard let encrypted = encrypt(value, forKey: key) else { return }
        defaults.set(encrypted, forKey: protectedKey(for: key))
        defaults.removeObject(forKey: key)
    }
}

enum ProtectedPreferences {
    private static let store = ProtectedPreferenceStore()
    static func data(forKey key: String) -> Data? { store.data(forKey: key) }
    @discardableResult static func set(_ value: Data?, forKey key: String) -> Bool { store.set(value, forKey: key) }
    static func remove(forKey key: String) { store.remove(forKey: key) }
    static func removeAll() { store.removeAll() }
    static func string(forKey key: String) -> String? { store.string(forKey: key) }
    @discardableResult static func set(_ value: String, forKey key: String) -> Bool { store.set(value, forKey: key) }
    static func stringArray(forKey key: String) -> [String]? { store.stringArray(forKey: key) }
    @discardableResult static func set(_ value: [String], forKey key: String) -> Bool { store.set(value, forKey: key) }
}
