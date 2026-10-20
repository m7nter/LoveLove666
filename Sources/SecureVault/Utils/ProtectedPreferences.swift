import Foundation

/// Stores small sensitive preferences as CryptoKit ciphertext rather than as
/// readable values in the application's preferences plist. Values written by
/// older releases are migrated opportunistically and removed only after the
/// encrypted copy has been saved successfully.
enum ProtectedPreferences {
    private static let prefix = "protected."

    // Keys are deliberately kept in one place so a destructive reset cannot
    // leave encrypted preference blobs behind after the vault key is removed.
    private static let sensitiveKeys = [
        "calculator.history.v2", "pendingCaptureEvent", "labelTemplates",
        "selectedTemplate", "userAvatar"
    ]

    private static func protectedKey(for key: String) -> String { prefix + key }

    static func data(forKey key: String) -> Data? {
        let defaults = UserDefaults.standard
        let encryptedKey = protectedKey(for: key)
        if let encrypted = defaults.data(forKey: encryptedKey),
           let value = CryptoManager.decrypt(encrypted) {
            return value
        }
        guard let legacy = defaults.data(forKey: key) else { return nil }
        migrate(legacy, forKey: key)
        return legacy
    }

    static func set(_ value: Data?, forKey key: String) {
        let defaults = UserDefaults.standard
        let encryptedKey = protectedKey(for: key)
        guard let value else {
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: encryptedKey)
            return
        }
        guard let encrypted = CryptoManager.encrypt(value) else {
            // Protected data may be unavailable during a lock transition.
            // Retain the old value instead of losing a user's edit.
            if defaults.data(forKey: encryptedKey) == nil { defaults.set(value, forKey: key) }
            return
        }
        defaults.set(encrypted, forKey: encryptedKey)
        defaults.removeObject(forKey: key)
    }

    static func remove(forKey key: String) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: protectedKey(for: key))
    }

    static func removeAll() {
        sensitiveKeys.forEach { remove(forKey: $0) }
        // Remove any future protected entries from a previous version too.
        let defaults = UserDefaults.standard
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) }
            .forEach { defaults.removeObject(forKey: $0) }
    }

    static func string(forKey key: String) -> String? {
        if let data = data(forKey: key) { return String(data: data, encoding: .utf8) }
        guard let legacy = UserDefaults.standard.string(forKey: key) else { return nil }
        migrate(Data(legacy.utf8), forKey: key)
        return legacy
    }

    static func set(_ value: String, forKey key: String) { set(Data(value.utf8), forKey: key) }

    static func stringArray(forKey key: String) -> [String]? {
        if let data = data(forKey: key) { return try? JSONDecoder().decode([String].self, from: data) }
        let legacy = UserDefaults.standard.stringArray(forKey: key)
        if let legacy { migrate(legacy, forKey: key) }
        return legacy
    }

    static func set(_ value: [String], forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        set(data, forKey: key)
    }

    private static func migrate(_ value: [String], forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        migrate(data, forKey: key)
    }

    private static func migrate(_ value: Data, forKey key: String) {
        guard let encrypted = CryptoManager.encrypt(value) else { return }
        let defaults = UserDefaults.standard
        defaults.set(encrypted, forKey: protectedKey(for: key))
        defaults.removeObject(forKey: key)
    }
}
