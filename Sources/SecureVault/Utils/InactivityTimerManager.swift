import Foundation
import Combine
import Security

protocol InactivityStateStore {
    func read(_ account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func delete(_ account: String) throws
}

struct KeychainInactivityStateStore: InactivityStateStore {
    let service: String
    init(service: String = "com.securevault.deadmanswitch") { self.service = service }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func read(_ account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        guard let data = result as? Data else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
    func write(_ data: Data, account: String) throws {
        let update: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(account) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        var insert = query(account)
        update.forEach { insert[$0.key] = $0.value }
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
    }
    func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

/// The mode and both clocks are a single atomic Keychain value. A failed
/// activation must not disable the previously active protection or erase its
/// last valid marker. The old three-item format remains readable on upgrade.
final class InactivityTimerManager: ObservableObject {
    static let shared = InactivityTimerManager()
    static let allowedIntervals: [Int] = [0, 24, 48, 72, 168]
    static let clockTamperBuffer: TimeInterval = 600
    private static let stateAccount = "state.v2"
    private struct State: Codable {
        let limitHours: Int
        let wall: TimeInterval?
        let uptime: TimeInterval?
    }
    @Published private(set) var limitHours: Int
    @Published private(set) var lastError: String?
    private let store: InactivityStateStore
    private let wallClock: () -> TimeInterval
    private let uptimeClock: () -> TimeInterval

    init(store: InactivityStateStore = KeychainInactivityStateStore(),
         wallClock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
         uptimeClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.store = store; self.wallClock = wallClock; self.uptimeClock = uptimeClock
        limitHours = (try? Self.readState(from: store).limitHours) ?? 0
    }
    var isEnabled: Bool { limitHours > 0 }
    var activeLimitHours: Int? { isEnabled ? limitHours : nil }

    private static func readState(from store: InactivityStateStore) throws -> State {
        if let data = try store.read(stateAccount) {
            let value = try JSONDecoder().decode(State.self, from: data)
            guard allowedIntervals.contains(value.limitHours) else { throw CocoaError(.fileReadCorruptFile) }
            return value
        }
        func legacy(_ account: String) throws -> String? {
            guard let data = try store.read(account), let value = String(data: data, encoding: .utf8) else { return nil }
            return value
        }
        let hours = try legacy("limitHours").flatMap(Int.init) ?? 0
        guard allowedIntervals.contains(hours) else { throw CocoaError(.fileReadCorruptFile) }
        return try State(limitHours: hours, wall: legacy("lastWallClock").flatMap(Double.init),
                         uptime: legacy("lastSystemUptime").flatMap(Double.init))
    }
    private func persist(_ state: State) throws {
        try store.write(JSONEncoder().encode(state), account: Self.stateAccount)
        // The new item is authoritative before removing the old timestamps.
        for account in ["limitHours", "lastWallClock", "lastSystemUptime"] { try? store.delete(account) }
    }
    private func currentState(hours: Int) throws -> State {
        let wall = wallClock(), uptime = uptimeClock()
        guard wall.isFinite, uptime.isFinite, wall >= 0, uptime >= 0 else { throw CocoaError(.fileWriteUnknown) }
        return State(limitHours: hours, wall: wall, uptime: uptime)
    }
    @discardableResult func activate(hours: Int) -> Bool {
        guard Self.allowedIntervals.contains(hours), hours > 0 else { return false }
        do {
            try persist(currentState(hours: hours))
            limitHours = hours; lastError = nil
            return true
        } catch {
            lastError = "Не удалось сохранить режим и контроль времени в Keychain. Предыдущая настройка сохранена."
            return false
        }
    }
    func disable() {
        do {
            // An explicit disabled record takes precedence over legacy items.
            // Ignoring a failed delete previously disabled only the UI.
            try persist(State(limitHours: 0, wall: nil, uptime: nil))
            limitHours = 0; lastError = nil
        } catch { lastError = "Не удалось выключить режим в Keychain. Защита остаётся включённой." }
    }
    @discardableResult func recordActivity() -> Bool {
        guard let limit = activeLimitHours else { return true }
        guard !shouldWipeData(limitHours: limit) else { return false }
        do {
            try persist(currentState(hours: limit))
            lastError = nil
            return true
        } catch {
            lastError = "Не удалось обновить контроль времени в Keychain."
            return false
        }
    }
    func shouldWipeData(limitHours: Int) -> Bool {
        guard limitHours > 0 else { return false }
        do {
            let state = try Self.readState(from: store)
            guard state.limitHours == limitHours, let wall = state.wall, let uptime = state.uptime else { throw CocoaError(.fileReadCorruptFile) }
            return Self.shouldWipeData(limitHours: limitHours, savedWall: wall, savedUptime: uptime,
                                      currentWall: wallClock(), currentUptime: uptimeClock())
        } catch {
            lastError = "Не удалось подтвердить контроль времени. Данные будут уничтожены для безопасности."
            return true
        }
    }
    static func shouldWipeData(limitHours: Int, savedWall: TimeInterval,
                               savedUptime: TimeInterval, currentWall: TimeInterval,
                               currentUptime: TimeInterval) -> Bool {
        guard limitHours > 0 else { return false }
        guard savedWall.isFinite, savedUptime.isFinite,
              currentWall.isFinite, currentUptime.isFinite,
              savedWall >= 0, savedUptime >= 0, currentWall >= 0, currentUptime >= 0 else { return true }
        let wallDelta = currentWall - savedWall
        let limit = Double(limitHours) * 3600
        if wallDelta < -Self.clockTamperBuffer { return true }
        if currentUptime >= savedUptime {
            let uptimeDelta = currentUptime - savedUptime
            if wallDelta < uptimeDelta - Self.clockTamperBuffer { return true }
            return max(0, wallDelta) >= limit || uptimeDelta >= limit
        }
        // After a reboot use wall time, retaining the direct rollback check.
        return wallDelta >= limit
    }
    func clearMarkers() {
        do { try persist(State(limitHours: limitHours, wall: nil, uptime: nil)) }
        catch { lastError = "Не удалось очистить контроль времени в Keychain." }
    }
}
