import SwiftUI

enum ActionButtonMode: String, CaseIterable, Identifiable {
    case off, camera, photos, reset, disable
    var id: String { rawValue }
    var destructive: Bool { self == .photos || self == .reset || self == .disable }
    var title: String {
        switch self {
        case .off: return "Выключено"
        case .camera: return "Открыть камеру"
        case .photos: return "Удалить все фото"
        case .reset: return "Сбросить все данные"
        case .disable: return "Стереть данные и сбросить вход"
        }
    }
    var detail: String {
        switch self {
        case .off: return "Команда Action Button не выполняется."
        case .camera: return "Камера открывается без основного пароля."
        case .photos: return "Удаляются фото, папки снимков, подписи к фото и временные экспорты. Дневник и настройки остаются."
        case .reset: return "Удаляются фото, дневник, метаданные, настройки, пароли, шаблоны и ключ шифрования. Приложение возвращается к первоначальным настройкам."
        case .disable: return "Удаляются данные, ключ шифрования и старые коды. После очистки можно сразу создать новое пустое хранилище. Постоянной блокировки приложения больше нет."
        }
    }
}

enum ActionButtonRouter {
    static func resolve(_ url: URL, mode: ActionButtonMode, token: String?) -> ActionButtonMode? {
        guard url.scheme?.lowercased() == "securevault", url.path.isEmpty || url.path == "/" else { return nil }
        if url.host == "camera" { return mode == .camera ? .camera : nil }
        guard url.host == "action", mode.destructive, let token = token, !token.isEmpty,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.count == 1, items[0].name == "token", items[0].value == token else { return nil }
        return mode
    }
}

// A single gate serializes storage mutations with erasure. Generation checks
// reject old camera/editor/export callbacks even after a non-permanent reset.
final class VaultGate {
    static let shared = VaultGate(blocked: UserDefaults.standard.bool(forKey: "vaultDisabled")
        || UserDefaults.standard.string(forKey: "pendingEraseMode") != nil
        || FileManager.default.fileExists(atPath: VaultDirectories.application.disabledMarker.path)
        || FileManager.default.fileExists(atPath: VaultDirectories.application.pendingMarker.path),
        generation: UserDefaults.standard.integer(forKey: "vaultGeneration"))
    private let lock = NSRecursiveLock()
    private var blocked: Bool
    private var epoch: Int
    init(blocked: Bool = false, generation: Int = 0) { self.blocked = blocked; epoch = generation }
    var generation: Int { lock.lock(); defer { lock.unlock() }; return epoch }
    func withAccess<T>(generation: Int? = nil, _ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard !blocked, generation == nil || generation == epoch else { throw CocoaError(.fileReadNoPermission) }
        return try body()
    }
    @discardableResult func revoke() -> Int {
        lock.lock(); defer { lock.unlock() }; blocked = true; epoch += 1; return epoch
    }
    func allow() {
        lock.lock(); defer { lock.unlock() }
        guard !UserDefaults.standard.bool(forKey: "vaultDisabled"),
              !FileManager.default.fileExists(atPath: VaultDirectories.application.disabledMarker.path),
              UserDefaults.standard.string(forKey: "pendingEraseMode") == nil,
              !FileManager.default.fileExists(atPath: VaultDirectories.application.pendingMarker.path) else { return }
        blocked = false
    }
    func duringErase<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
}

struct VaultDirectories {
    let documents: URL
    let caches: URL
    let temporary: URL
    let support: URL
    static var application: VaultDirectories {
        let fm = FileManager.default
        return VaultDirectories(documents: fm.urls(for: .documentDirectory, in: .userDomainMask)[0],
            caches: fm.urls(for: .cachesDirectory, in: .userDomainMask)[0], temporary: fm.temporaryDirectory,
            support: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }
    var disabledMarker: URL { support.appendingPathComponent("VaultDisabled.flag") }
    var pendingMarker: URL { support.appendingPathComponent("VaultErase.pending") }
}

struct VaultEraseService {
    let directories: VaultDirectories
    let defaults: UserDefaults
    let defaultsDomain: String
    let destroyKey: () throws -> Void
    let destroyCodes: () throws -> Void
    let preservedSupportEntries: Set<String>
    private let fm = FileManager.default
    init(directories: VaultDirectories, defaults: UserDefaults, defaultsDomain: String,
         destroyKey: @escaping () throws -> Void, destroyCodes: @escaping () throws -> Void = {},
         preservedSupportEntries: Set<String> = []) {
        self.directories = directories; self.defaults = defaults
        self.defaultsDomain = defaultsDomain; self.destroyKey = destroyKey; self.destroyCodes = destroyCodes
        self.preservedSupportEntries = preservedSupportEntries
    }

    func prepare(_ mode: ActionButtonMode, generation: Int) throws {
        guard mode.destructive else { throw CocoaError(.featureUnsupported) }
        defaults.set(mode.rawValue, forKey: "pendingEraseMode")
        defaults.set(generation, forKey: "vaultGeneration")
        if mode == .disable { defaults.set(true, forKey: "vaultDisabled") }
        // Persist the deny flag before any file work. A failed marker write
        // must not reopen the vault on the next launch.
        guard defaults.synchronize() else { throw CocoaError(.fileWriteUnknown) }
        try fm.createDirectory(at: directories.support, withIntermediateDirectories: true)
        try Data(mode.rawValue.utf8).write(to: directories.pendingMarker,
                                           options: [.atomic, .completeFileProtection])
        if mode == .disable {
            try Data("disabled".utf8).write(to: directories.disabledMarker,
                                             options: [.atomic, .completeFileProtection])
        }
    }

    func prepareCryptographicReset(_ mode: ActionButtonMode) throws {
        if mode == .reset || mode == .disable { try destroyKey(); try destroyCodes() }
    }

    func erase(_ mode: ActionButtonMode, generation: Int, cryptographicResetPrepared: Bool = false) throws {
        guard mode.destructive else { throw CocoaError(.featureUnsupported) }
        // Destroy the key first; a failed deletion keeps the application closed.
        if !cryptographicResetPrepared { try prepareCryptographicReset(mode) }
        var failures: [Error] = []
        func remove(_ url: URL) {
            guard fm.fileExists(atPath: url.path) else { return }
            do { try fm.removeItem(at: url) } catch { failures.append(error) }
        }
        func clear(_ directory: URL, preserving: Set<String> = []) {
            guard fm.fileExists(atPath: directory.path) else { return }
            do {
                for item in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                    if !preserving.contains(item.lastPathComponent) { remove(item) }
                }
            } catch { failures.append(error) }
        }
        if mode == .photos { remove(directories.documents.appendingPathComponent("VaultPhotos")) }
        else {
            clear(directories.documents)
            clear(directories.support, preserving: Set(["VaultDisabled.flag", "VaultErase.pending"]).union(preservedSupportEntries))
        }
        clear(directories.caches); clear(directories.temporary)
        guard failures.isEmpty else { throw failures[0] }
        // Recovery is a full reset, never an unlock of the old material.
        // Keep the deny marker until keys, codes and all files are erased.
        // The pending marker continues to block access if this step fails.
        if mode != .photos, fm.fileExists(atPath: directories.disabledMarker.path) {
            try fm.removeItem(at: directories.disabledMarker)
        }
        if mode != .photos { defaults.removePersistentDomain(forName: defaultsDomain) }
        defaults.removeObject(forKey: "pendingCaptureEvent")
        if mode != .photos { ProtectedPreferences.removeAll() }
        else { ProtectedPreferences.remove(forKey: "pendingCaptureEvent") }
        defaults.set(generation, forKey: "vaultGeneration")
        if mode == .photos {
            try fm.createDirectory(at: directories.documents.appendingPathComponent("VaultPhotos"), withIntermediateDirectories: true)
        }
        defaults.removeObject(forKey: "pendingEraseMode")
        // Persist completion before removing the on-disk recovery marker.
        guard defaults.synchronize() else { throw CocoaError(.fileWriteUnknown) }
        if fm.fileExists(atPath: directories.pendingMarker.path) { try fm.removeItem(at: directories.pendingMarker) }
    }
}

final class VaultLifecycle: ObservableObject {
    static let shared = VaultLifecycle()
    @Published private(set) var isErasing = false
    @Published private(set) var disabled: Bool
    @Published private(set) var lastError: String?
    @Published private(set) var generation: Int
    var blocksUI: Bool { disabled || isErasing || lastError != nil }
    var canRetry: Bool { pendingMode != nil }
    private let directories = VaultDirectories.application
    private var pendingMode: ActionButtonMode?
    private let queue = DispatchQueue(label: "SecureVault.erase", qos: .userInitiated)

    private init() {
        disabled = UserDefaults.standard.bool(forKey: "vaultDisabled")
            || FileManager.default.fileExists(atPath: VaultDirectories.application.disabledMarker.path)
        generation = VaultGate.shared.generation
        let recorded = UserDefaults.standard.string(forKey: "pendingEraseMode")
            ?? (try? String(contentsOf: VaultDirectories.application.pendingMarker, encoding: .utf8))
        let recovered = recorded.flatMap(ActionButtonMode.init(rawValue:))
        pendingMode = recovered?.destructive == true ? recovered : nil
        let hasRecord = recorded != nil || FileManager.default.fileExists(atPath: VaultDirectories.application.pendingMarker.path)
        if disabled || hasRecord { _ = VaultGate.shared.revoke() }
        if pendingMode != nil { lastError = "Нужно завершить удаление данных." }
        else if hasRecord { lastError = "Запись удаления повреждена. Доступ к приложению закрыт." }
    }
    // Legacy permanent locks and corrupt erase records become a fresh setup.
    // Complete erasure first; never expose old material by merely clearing flags.
    func resumePendingErase() {
        if let mode = pendingMode { erase(mode) }
        else if disabled || lastError != nil { erase(.reset) }
    }
    func retry() { if let mode = pendingMode { erase(mode) } }
    func erase(_ mode: ActionButtonMode) {
        guard mode.destructive, !isErasing else { return }
        isErasing = true; lastError = nil; pendingMode = mode
        let epoch = VaultGate.shared.revoke()
        generation = epoch
        if mode == .disable { disabled = true }
        let service = VaultEraseService(directories: directories, defaults: .standard,
            defaultsDomain: Bundle.main.bundleIdentifier ?? "com.securevault.app",
            destroyKey: { try CryptoManager.destroyKey() },
            destroyCodes: { try KeychainCodeStore.deleteAll() },
            preservedSupportEntries: [Bundle.main.bundleIdentifier ?? "com.securevault.app"])
        NotificationCenter.default.post(name: .vaultWillErase, object: nil)
        do {
            try service.prepare(mode, generation: epoch)
        }
        catch { isErasing = false; lastError = "Не удалось подготовить удаление: \(error.localizedDescription)"; return }
        // Let app initialization finish before accessing the protected Keychain.
        DispatchQueue.main.async {
            do {
                // A map error must never preserve a usable vault key.
                try service.prepareCryptographicReset(mode)
            } catch {
                self.isErasing = false
                self.lastError = "Не удалось удалить ключи входа: \(error.localizedDescription)"
                return
            }
            OfflineMapManager.shared.prepareForErase(mode) { mapError in
                if let mapError {
                    self.isErasing = false
                    self.lastError = "Не удалось очистить офлайн-карты: \(mapError.localizedDescription)"
                    return
                }
                self.erasePreparedFiles(service, mode: mode, generation: epoch)
            }
        }
    }

    private func erasePreparedFiles(_ service: VaultEraseService, mode: ActionButtonMode, generation: Int) {
        queue.async {
            let result = Result {
                try VaultGate.shared.duringErase {
                    try service.erase(mode, generation: generation, cryptographicResetPrepared: true)
                }
            }
            DispatchQueue.main.async {
                self.isErasing = false
                switch result {
                case .success:
                    self.pendingMode = nil
                    if mode != .photos {
                        self.disabled = false
                        SettingsStore.shared.resetToFactory()
                    }
                    NotesManager.shared.lastError = nil
                    VaultGate.shared.allow()
                case .failure(let error):
                    self.lastError = "Удаление не завершено: \(error.localizedDescription)"
                }
            }
        }
    }
}

extension Notification.Name { static let vaultWillErase = Notification.Name("vaultWillErase") }
