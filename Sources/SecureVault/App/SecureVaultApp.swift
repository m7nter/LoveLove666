import SwiftUI

@main
struct SecureVaultApp: App {
    @State private var isUnlocked = false
    @State private var isCameraOnly = false
    @State private var backgroundTime: Date? = nil
    @State private var inactivityTimer: Timer? = nil
    @State private var showsRecovery = false
    @Environment(\.scenePhase) var scenePhase
    @StateObject private var lifecycle = VaultLifecycle.shared

    init() {
        #if DEBUG && targetEnvironment(simulator)
        // UI-test fixtures are excluded from the device IPA.
        if ProcessInfo.processInfo.arguments.contains("--test-legacy-lock") {
            let paths = VaultDirectories.application
            try? FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
            try? Data("disabled".utf8).write(to: paths.disabledMarker)
            UserDefaults.standard.set(true, forKey: "vaultDisabled")
        }
        if ProcessInfo.processInfo.arguments.contains("--test-calculator") {
            try? KeychainCodeStore.write("1357", for: "mainCode")
            UserDefaults.standard.set(2, forKey: "vaultAccessFlowVersion")
        }
        if ProcessInfo.processInfo.arguments.contains("--test-gallery") {
            let storage = FileStorageManager.shared
            for url in storage.loadAll() { storage.delete(url: url) }
            let eventID = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
            for index in 1...2 {
                let size = index == 1 ? CGSize(width: 400, height: 300) : CGSize(width: 300, height: 400)
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    UIColor.orange.setFill(); UIRectFill(CGRect(origin: .zero, size: size))
                    UIColor.blue.setFill(); UIRectFill(CGRect(x: 10, y: 10, width: size.width - 20, height: size.height - 20))
                }
                let context = CaptureContext(eventID: eventID, folder: "0.5", expectedCount: 2,
                    index: index, eventNumber: 1, generation: VaultGate.shared.generation)
                _ = storage.save(image: image, context: context)
            }
        }
        #endif
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
            if lifecycle.blocksUI && showsRecovery {
                VaultRecoveryView(lifecycle: lifecycle, onCalculator: { showsRecovery = false })
            } else {
            RootView(
                isUnlocked: $isUnlocked,
                isCameraOnly: $isCameraOnly,
                onStartTimer: startTimer,
                onStopTimer: stopTimer,
                onBlockedAccess: { showsRecovery = true }
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
                    if phase == .background && !lifecycle.blocksUI && SettingsStore.shared.lockOnBackground && isUnlocked {
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
    let onBlockedAccess: () -> Void
    @State private var needsSetup = false
    @State private var showAccess = false
    @State private var accessError: String?

    var body: some View {
        Group {
            if showAccess, let accessError {
                VStack(spacing: 20) {
                    Text("Не удалось прочитать код") .font(.title2)
                    Text(accessError).font(.callout)
                    Button("Повторить") { refreshAccess() }
                    VaultResetButton()
                    Button("Калькулятор") { showAccess = false }
                }.padding(24)
            } else if showAccess {
                VaultAccessView(isSetup: needsSetup, onAuthorized: unlock,
                    onCalculator: { showAccess = false })
            } else if isCameraOnly {
                VaultView(cameraOnly: true, onLock: lock)
            } else if isUnlocked {
                VaultView(onLock: lock)
            } else {
                CalculatorView(onUnlock: unlock, onAccess: openHiddenAccess)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func refreshAccess() {
        do {
            let code = try KeychainCodeStore.readChecked("mainCode")
            needsSetup = code.isEmpty || code == "2026"
            accessError = nil
        } catch {
            accessError = "Защищённое хранилище iOS: \(error.localizedDescription). Код ошибки: \((error as NSError).code)."
        }
    }
    private func openHiddenAccess() {
        guard !VaultLifecycle.shared.blocksUI else { onBlockedAccess(); return }
        refreshAccess()
        showAccess = true
    }
    private func unlock() {
        guard !VaultLifecycle.shared.blocksUI,
              (try? VaultGate.shared.withAccess { true }) == true else { return }
        needsSetup = false; showAccess = false
        isUnlocked = true; isCameraOnly = false
        onStartTimer()
    }
    private func lock() {
        isUnlocked = false; isCameraOnly = false
        showAccess = false
        onStopTimer()
        PhotoExporter.cleanupTemporaryExports()
    }
}
