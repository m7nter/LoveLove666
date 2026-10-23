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
        #endif
        prepareInstallIdentity()
        setupCrashLogging()
        PhotoExporter.cleanupTemporaryExports()
        let lifecycle = VaultLifecycle.shared
        let inactivity = InactivityTimerManager.shared
        #if DEBUG && targetEnvironment(simulator)
        let isTestFixture = ProcessInfo.processInfo.arguments.contains("--test-legacy-lock")
            || ProcessInfo.processInfo.arguments.contains("--test-calculator")
        #else
        let isTestFixture = false
        #endif
        if !isTestFixture, let limit = inactivity.activeLimitHours,
           inactivity.shouldWipeData(limitHours: limit) {
            // Clear the marker before scheduling the reset so a failed or
            // interrupted erase cannot repeatedly trigger a second request.
            inactivity.clearMarkers()
            lifecycle.erase(.reset)
        }
        if !lifecycle.blocksUI {
            _ = SettingsStore.shared
            DispatchQueue.global(qos: .utility).async {
                _ = FileStorageManager.shared
                NotesManager.shared.migrateLegacyIfNeeded()
            }
        }
        lifecycle.resumePendingErase()
    }

    private func prepareInstallIdentity() {
        let paths = VaultDirectories.application
        let fileManager = FileManager.default
        let marker = paths.support.appendingPathComponent(".install-marker")
        guard !fileManager.fileExists(atPath: marker.path),
              !fileManager.fileExists(atPath: paths.pendingMarker.path),
              !fileManager.fileExists(atPath: paths.disabledMarker.path) else { return }

        let hasExistingContainerData = [paths.documents, paths.support].contains { directory in
            (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty == false) ?? false
        }
        // A reinstall removes the app container but leaves this app's Keychain
        // entries behind. Do not let those stale codes unlock an empty install.
        // If an older app version already has files, this is an upgrade and the
        // existing keychain material must be preserved.
        if !hasExistingContainerData {
            try? KeychainCodeStore.deleteAll()
            try? CryptoManager.destroyKey()
        }
        try? fileManager.createDirectory(at: paths.support, withIntermediateDirectories: true)
        try? Data("1".utf8).write(to: marker, options: [.atomic, .completeFileProtection])
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
                    if !lifecycle.blocksUI {
                        guard enforceInactivityIfNeeded() else {
                            backgroundTime = nil
                            return
                        }
                        if let bg = backgroundTime, !SettingsStore.shared.lockOnBackground {
                            let elapsed = Date().timeIntervalSince(bg)
                            let timeout = SettingsStore.shared.autoLockTimeout
                            if timeout > 0 && elapsed >= Double(timeout) && isUnlocked {
                                isUnlocked = false
                            } else if isUnlocked {
                                startTimer()
                            }
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

    /// Checks the Dead Man's Switch on every return to the active scene, not
    /// only during App.init. This closes the warm-resume path where iOS keeps
    /// the process alive across the configured deadline.
    private func enforceInactivityIfNeeded() -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--test-legacy-lock") || args.contains("--test-calculator") { return true }
        #endif
        guard let limit = InactivityTimerManager.shared.activeLimitHours else { return true }
        guard InactivityTimerManager.shared.shouldWipeData(limitHours: limit) else { return true }
        InactivityTimerManager.shared.clearMarkers()
        stopTimer()
        isUnlocked = false
        isCameraOnly = false
        VaultLifecycle.shared.erase(.reset)
        return false
    }

    private func setupCrashLogging() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: caches.appendingPathComponent("crash.log"))
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
    @State private var showWelcomePrompt = false
    @State private var showWelcomeGuide = false
    @State private var accessError: String?
    @State private var accessChecked = false
    @AppStorage("welcomeGuidePromptVersion") private var welcomeGuidePromptVersion = 0

    var body: some View {
        Group {
            if !accessChecked {
                ProgressView().tint(.white)
                    .task { refreshAccess(initial: true) }
            } else if showAccess, let accessError {
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
                CalculatorView(onUnlock: unlock, onAccess: openHiddenAccess,
                               vaultEntryEnabled: !needsSetup)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showWelcomePrompt) {
            WelcomeGuidePromptView(
                onGuide: {
                    welcomeGuidePromptVersion = 1
                    showWelcomePrompt = false
                    DispatchQueue.main.async {
                        showWelcomeGuide = true
                    }
                },
                onExperienced: {
                    welcomeGuidePromptVersion = 1
                    showWelcomePrompt = false
                }
            )
        }
        .sheet(isPresented: $showWelcomeGuide) {
            WelcomeGuideView()
        }
    }

    private func refreshAccess(initial: Bool = false) {
        do {
            let code = try KeychainCodeStore.readChecked("mainCode")
            needsSetup = code.isEmpty || code == "2026"
            accessError = nil
            accessChecked = true
            if initial && needsSetup && !isUITestFixture { showAccess = true }
        } catch {
            if initial {
                // A reinstall may retain an inaccessible keychain item. Treat it as a
                // fresh install so the user can establish a new code.
                needsSetup = true
                accessError = nil
                accessChecked = true
                if !isUITestFixture { showAccess = true }
            } else {
                accessError = "Защищённое хранилище iOS: \(error.localizedDescription). Код ошибки: \((error as NSError).code)."
            }
        }
    }
    private var isUITestFixture: Bool {
        #if DEBUG && targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--test-legacy-lock") || args.contains("--test-calculator")
        #else
        return false
        #endif
    }
    private func openHiddenAccess() {
        guard !VaultLifecycle.shared.blocksUI else { onBlockedAccess(); return }
        refreshAccess()
        showAccess = true
    }
    private func unlock() {
        guard !VaultLifecycle.shared.blocksUI,
              (try? VaultGate.shared.withAccess { true }) == true else { return }
        guard InactivityTimerManager.shared.recordActivity() else {
            VaultLifecycle.shared.erase(.reset)
            return
        }
        let wasSetup = needsSetup
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--test-gallery") {
            // Encryption is available after launch, never during App.init.
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
                precondition(storage.save(image: image, context: context) != nil, "UI test photo could not be saved")
            }
        }
        #endif
        needsSetup = false; showAccess = false
        isUnlocked = true; isCameraOnly = false
        onStartTimer()
        if wasSetup && welcomeGuidePromptVersion == 0 && !isUITestFixture {
            showWelcomePrompt = true
        }
    }
    private func lock() {
        isUnlocked = false; isCameraOnly = false
        showAccess = false
        onStopTimer()
        PhotoExporter.cleanupTemporaryExports()
    }

}
