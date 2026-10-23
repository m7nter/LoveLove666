import Foundation
import Combine
import Security

/// Dead Man's Switch state. The timestamps are kept outside UserDefaults so
/// changing a preferences plist cannot postpone the wipe.
final class InactivityTimerManager: ObservableObject {
    static let shared = InactivityTimerManager()

    static let allowedIntervals: [Int] = [0, 24, 48, 72, 168]
    static let clockTamperBuffer: TimeInterval = 600

    @Published private(set) var limitHours: Int
    @Published private(set) var lastError: String?

    private let service = "com.securevault.deadmanswitch"
    private let wallAccount = "lastWallClock"
    private let uptimeAccount = "lastSystemUptime"
    private let limitAccount = "limitHours"

    private init() {
        limitHours = Self.readKeychainInt(service: service, account: limitAccount) ?? 0
    }

    var isEnabled: Bool { limitHours > 0 }
    var activeLimitHours: Int? { limitHours > 0 ? limitHours : nil }

    /// Enables the switch and writes a fresh activity marker atomically enough
    /// for a failed Keychain write to leave the old setting untouched.
    @discardableResult
    func activate(hours: Int) -> Bool {
        guard Self.allowedIntervals.contains(hours), hours > 0 else { return false }
        guard writeKeychainInt(hours, account: limitAccount) else {
            lastError = "Не удалось сохранить режим безопасности в Keychain."
            return false
        }
        guard writeActivityMarker() else {
            deleteKeychain(account: limitAccount)
            limitHours = 0
            lastError = "Не удалось сохранить контроль времени в Keychain."
            return false
        }
        limitHours = hours
        lastError = nil
        return true
    }

    func disable() {
        deleteKeychain(account: limitAccount)
        clearMarkers()
        limitHours = 0
        lastError = nil
    }

    /// Records a successful unlocked session. If the existing marker already
    /// says the switch must fire, refuse to refresh it so a clock rollback
    /// cannot be hidden by immediately opening the app.
    @discardableResult
    func recordActivity() -> Bool {
        guard let limit = activeLimitHours else { return true }
        if shouldWipeData(limitHours: limit) { return false }
        let ok = writeActivityMarker()
        if !ok { lastError = "Не удалось обновить контроль времени в Keychain." }
        return ok
    }

    /// Returns true when the selected inactivity interval elapsed or the wall
    /// clock moved backwards relative to monotonic system uptime.
    func shouldWipeData(limitHours: Int) -> Bool {
        guard limitHours > 0 else { return false }
        guard let savedWall = readKeychainDouble(account: wallAccount),
              let savedUptime = readKeychainDouble(account: uptimeAccount),
              savedWall.isFinite, savedUptime.isFinite,
              savedWall >= 0, savedUptime >= 0 else {
            // Once the limit is active, a missing or corrupt marker is
            // indistinguishable from tampering or an incomplete reset. Fail
            // closed instead of silently extending the destruction deadline.
            lastError = "Не удалось подтвердить контроль времени. Данные будут уничтожены для безопасности."
            return true
        }

        return Self.shouldWipeData(limitHours: limitHours,
                                    savedWall: savedWall,
                                    savedUptime: savedUptime,
                                    currentWall: Date().timeIntervalSince1970,
                                    currentUptime: ProcessInfo.processInfo.systemUptime)
    }

    static func shouldWipeData(limitHours: Int, savedWall: TimeInterval,
                               savedUptime: TimeInterval, currentWall: TimeInterval,
                               currentUptime: TimeInterval) -> Bool {
        guard limitHours > 0 else { return false }
        guard savedWall.isFinite, savedUptime.isFinite,
              currentWall.isFinite, currentUptime.isFinite,
              savedWall >= 0, savedUptime >= 0 else { return true }
        let wallDelta = currentWall - savedWall
        let limit = Double(limitHours) * 3600

        // A large negative wall delta is a direct rollback signal.
        if wallDelta < -Self.clockTamperBuffer { return true }

        if currentUptime >= savedUptime {
            let uptimeDelta = currentUptime - savedUptime
            // Monotonic time says the device was running longer than the wall
            // clock admits: the wall clock was moved backwards.
            if wallDelta < uptimeDelta - Self.clockTamperBuffer { return true }
            return max(0, wallDelta) >= limit || uptimeDelta >= limit
        }

        // Uptime resets after reboot. It cannot be compared across boots, so
        // use the wall clock while retaining the rollback check above.
        return wallDelta >= limit
    }

    func clearMarkers() {
        deleteKeychain(account: wallAccount)
        deleteKeychain(account: uptimeAccount)
    }

    private func writeActivityMarker() -> Bool {
        let wall = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), Date().timeIntervalSince1970)
        let uptime = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), ProcessInfo.processInfo.systemUptime)
        guard writeKeychain(wall, account: wallAccount) else { return false }
        guard writeKeychain(uptime, account: uptimeAccount) else {
            deleteKeychain(account: wallAccount)
            return false
        }
        return true
    }

    private func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func writeKeychainInt(_ value: Int, account: String) -> Bool {
        writeKeychain(String(value), account: account)
    }

    private func writeKeychain(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        var update = [String: Any]()
        update[kSecValueData as String] = data
        update[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemUpdate(query(account: account) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var insert = query(account: account)
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    private func readKeychain(_ account: String) -> String? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func readKeychainDouble(account: String) -> Double? { readKeychain(account).flatMap(Double.init) }
    private func deleteKeychain(account: String) { _ = SecItemDelete(query(account: account) as CFDictionary) }

    private static func readKeychainInt(service: String, account: String) -> Int? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              let hours = Int(value), Self.allowedIntervals.contains(hours) else { return nil }
        return hours
    }
}
