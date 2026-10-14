import SwiftUI

@main
struct SecureVaultApp: App {
    @State private var isUnlocked = false
    @State private var isCameraOnly = false
    @State private var backgroundTime: Date? = nil
    @State private var inactivityTimer: Timer? = nil
    @Environment(\.scenePhase) var scenePhase
    @StateObject private var lifecycle = VaultLifecycle.shared

    init() {
        setupCrashLogging()
        PhotoExporter.cleanupTemporaryExports()
        let lifecycle = VaultLifecycle.shared
        if !lifecycle.blocksUI {
            _ = SettingsStore.shared
            DispatchQueue.global(qos: .utility).async {
                _ = FileStorageManager.shared
                NotesManager.shared.migrateLegacyIfNeeded()
            }
        }
        lifecycle.resumePendingErase()
    }

    var body: some Scene {
        WindowGroup {
            Group {
            if lifecycle.blocksUI {
                CalculatorView(onUnlock: {})
            } else {
            RootView(
                isUnlocked: $isUnlocked,
                isCameraOnly: $isCameraOnly,
                onStartTimer: startTimer,
                onStopTimer: stopTimer
            )
            .id(lifecycle.generation)
            }
            }
            .onReceive(NotificationCenter.default.publisher(for: .vaultWillErase)) { _ in
                stopTimer(); isUnlocked = false; isCameraOnly = false
                VolumeButtonHandler.shared.stop()
                LocationManager.shared.stop()
            }
            .onReceive(NotificationCenter.default.publisher(for: .blackScreenChanged)) { notification in
                if notification.object as? Bool == true { stopTimer() }
                else if isUnlocked { startTimer() }
            }
            .onOpenURL { url in
                guard !lifecycle.blocksUI, let action = ActionButtonRouter.resolve(url,
                    mode: SettingsStore.shared.actionButtonMode, token: SettingsStore.shared.actionButtonToken) else { return }
                stopTimer()
                isUnlocked = false
                isCameraOnly = false
                if action.destructive { lifecycle.erase(action); return }
                guard (try? VaultGate.shared.withAccess { true }) == true else { return }
                isCameraOnly = true
            }
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .background, .inactive:
                    backgroundTime = Date()
                    stopTimer()
                    if !lifecycle.blocksUI && SettingsStore.shared.lockOnBackground && isUnlocked {
                        isUnlocked = false
                    }
                    if phase == .background && isCameraOnly {
                        isCameraOnly = false
                    }
                case .active:
                    if lifecycle.blocksUI { lifecycle.resumePendingErase() }
                    if !lifecycle.blocksUI, let bg = backgroundTime, !SettingsStore.shared.lockOnBackground {
                        let elapsed = Date().timeIntervalSince(bg)
                        let timeout = SettingsStore.shared.autoLockTimeout
                        if timeout > 0 && elapsed >= Double(timeout) && isUnlocked {
                            isUnlocked = false
                        } else if isUnlocked {
                            startTimer()
                        }
                    }
                    backgroundTime = nil
                default:
                    break
                }
            }
        }
    }

    private func startTimer() {
        stopTimer()
        guard !lifecycle.blocksUI else { return }
        let timeout = SettingsStore.shared.autoLockTimeout
        guard timeout > 0, !SettingsStore.shared.lockOnBackground else { return }
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: Double(timeout),
                                               repeats: false) { _ in
            DispatchQueue.main.async {
                isUnlocked = false
            }
        }
    }

    private func stopTimer() {
        inactivityTimer?.invalidate()
        inactivityTimer = nil
    }

    private func setupCrashLogging() {
        NSSetUncaughtExceptionHandler { exception in
            guard (try? VaultGate.shared.withAccess { true }) == true else { return }
            let log = """
            CRASH: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "unknown")
            Stack: \(exception.callStackSymbols.joined(separator: "\n"))
            """
            let paths = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)
            if let cachePath = paths.first {
                let logURL = URL(fileURLWithPath: cachePath).appendingPathComponent("crash.log")
                try? Data(log.utf8).write(to: logURL, options: [.atomic, .completeFileProtection])
            }
        }
    }
}

struct RootView: View {
    @Binding var isUnlocked: Bool
    @Binding var isCameraOnly: Bool
    let onStartTimer: () -> Void
    let onStopTimer: () -> Void
    @State private var needsInitialCode = false

    var body: some View {
        Group {
            if isCameraOnly {
                VaultView(cameraOnly: true, onLock: {
                    isCameraOnly = false
                    isUnlocked = false
                    onStopTimer()
                })
            } else if isUnlocked {
                VaultView(onLock: {
                    isUnlocked = false
                    onStopTimer()
                    PhotoExporter.cleanupTemporaryExports()
                })
            } else {
                CalculatorView(onUnlock: {
                    guard !VaultLifecycle.shared.blocksUI,
                          (try? VaultGate.shared.withAccess { true }) == true else { return }
                    if SettingsStore.shared.mainCode.isEmpty || SettingsStore.shared.mainCode == "2026" {
                        needsInitialCode = true
                        return
                    }
                    isUnlocked = true
                    onStartTimer()
                })
            }
        }
        .onAppear {
            guard !VaultLifecycle.shared.blocksUI else { return }
            let code = SettingsStore.shared.mainCode
            if code.isEmpty || code == "2026" { needsInitialCode = true }
        }
        .sheet(isPresented: $needsInitialCode) {
            ChangeCodeView(title: "Создайте личный код", currentCode: "2026", requireCurrent: false,
                           forbiddenCodes: ["2026", SettingsStore.shared.kamikazeCode], allowCancel: false) { code in
                SettingsStore.shared.mainCode = code
                return SettingsStore.shared.securityError == nil
            }
        }
    }
}
