import SwiftUI

@main
struct SecureVaultApp: App {
    @State private var isUnlocked = false
    @State private var isCameraOnly = false
    @State private var backgroundTime: Date? = nil
    @State private var inactivityTimer: Timer? = nil
    @State private var showsRecovery = false
    @State private var privacyCover = false
    @Environment(\.scenePhase) var scenePhase
    @StateObject private var lifecycle = VaultLifecycle.shared

    init() {
        #if DEBUG && targetEnvironment(simulator)
        // UI-test fixtures are excluded from the device IPA.
        if ProcessInfo.processInfo.arguments.contains("--test-legacy-lock") {
            let paths = VaultDirectories.application
            // This fixture models a separate reset installation. It must not
            // inherit a permanent lock left by a preceding destructive UI test.
            try? FileManager.default.removeItem(at: paths.bruteForceLockMarker)
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
        #if DEBUG && targetEnvironment(simulator)
        // The calculator UI fixture must also initialize the PIN-bound key;
        // production launches never execute this path.
        if ProcessInfo.processInfo.arguments.contains("--test-calculator") {
            try? KeychainCodeStore.write("1357", for: "mainCode")
            UserDefaults.standard.set(2, forKey: "vaultAccessFlowVersion")
            let testPaths = VaultDirectories.application
            try? FileManager.default.removeItem(at: testPaths.disabledMarker)
            try? FileManager.default.removeItem(at: testPaths.pendingMarker)
            UserDefaults.standard.removeObject(forKey: "vaultDisabled")
            UserDefaults.standard.removeObject(forKey: "pendingEraseMode")
            VaultGate.shared.allow()
            // Encrypted fixtures are prepared after protected data becomes
            // available, before the calculator is exposed to the UI test.
        }
        #endif
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
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--test-legacy-lock") {
            // @StateObject may construct the lifecycle before this fixture
            // writes its legacy marker. Explicitly run the real reset instead
            // of depending on the singleton's earlier cached marker state.
            lifecycle.erase(.reset)
        } else {
            lifecycle.resumePendingErase()
        }
        #else
        lifecycle.resumePendingErase()
        #endif
    }

    private func prepareInstallIdentity() {
        let paths = VaultDirectories.application
        let fileManager = FileManager.default
        let marker = paths.installMarker
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
            ZStack {
            Group {
            if lifecycle.blocksUI && showsRecovery {
                VaultRecoveryView(lifecycle: lifecycle, onCalculator: { showsRecovery = false })
            } else {
            RootView(
                isUnlocked: $isUnlocked,
                isCameraOnly: $isCameraOnly,
                onStartTimer: startTimer,
                onStopTimer: stopTimer
            )
            .id("\(lifecycle.generation):\(lifecycle.isErasing)")
            }
            }
            if privacyCover {
                Color.black.ignoresSafeArea()
                    .accessibilityHidden(true)
            }
            }
            .onReceive(NotificationCenter.default.publisher(for: .vaultWillErase)) { _ in
                stopTimer(); isUnlocked = false; isCameraOnly = false; showsRecovery = true
                VolumeButtonHandler.shared.stop()
                LocationManager.shared.stop()
            }
            .onAppear {
                if lifecycle.blocksUI { showsRecovery = true }
                configureContinuousGPS()
            }
            .onChange(of: isUnlocked) { unlocked in
                if !unlocked { CryptoManager.lockVault() }
                else { configureContinuousGPS() }
            }
            .onReceive(SettingsStore.shared.$continuousGPSEnabled.dropFirst()) { enabled in
                configureContinuousGPS(enabled: enabled)
            }
            .onChange(of: lifecycle.isErasing) { erasing in
                if !erasing { configureContinuousGPS() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
                // A device lock always ends the authenticated session, even
                // when the optional app-background grace period is enabled.
                stopTimer()
                isUnlocked = false
                isCameraOnly = false
                CryptoManager.lockVault()
            }
            .onReceive(NotificationCenter.default.publisher(for: .blackScreenChanged)) { notification in
                if notification.object as? Bool == true { stopTimer() }
                else if isUnlocked { startTimer() }
            }
            .onOpenURL { url in
                guard !lifecycle.isBruteForceLocked, !lifecycle.blocksUI, let action = ActionButtonRouter.resolve(url,
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
                    privacyCover = isUnlocked || isCameraOnly || showsRecovery
                    if phase == .background && !lifecycle.blocksUI && SettingsStore.shared.lockOnBackground && isUnlocked {
                        isUnlocked = false
                    }
                    if phase == .background && isCameraOnly {
                        isCameraOnly = false
                    }
                case .active:
                    privacyCover = false
                    configureContinuousGPS()
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

    private func configureContinuousGPS(enabled requestedValue: Bool? = nil) {
        #if DEBUG && targetEnvironment(simulator)
        // XCTest/UI fixtures manage their own deterministic coordinates and
        // must not acquire background GPS or present an extra permission alert.
        return
        #else
        let manager = LocationManager.shared
        guard !lifecycle.isErasing, !lifecycle.blocksUI, !lifecycle.isBruteForceLocked else {
            manager.stop(); return
        }
        let enabled = requestedValue ?? SettingsStore.shared.continuousGPSEnabled
        guard enabled else { manager.setContinuousUpdatesEnabled(false); return }
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        guard let code = try? KeychainCodeStore.readChecked("mainCode"), !code.isEmpty, code != "2026" else {
            manager.setContinuousUpdatesEnabled(false); return
        }
        manager.setContinuousUpdatesEnabled(true)
        #endif
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

}

struct RootView: View {
    @Binding var isUnlocked: Bool
    @Binding var isCameraOnly: Bool
    let onStartTimer: () -> Void
    let onStopTimer: () -> Void
    @State private var needsSetup = false
    @State private var showAccess = false
    @State private var showWelcomePrompt = false
    @State private var showWelcomeGuide = false
    #if DEBUG && targetEnvironment(simulator)
    @State private var showRadarPreview = false
    @State private var calculatorFixturePrepared = false
    #endif
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
                    Button("Калькулятор") { showAccess = false }
                }.padding(24)
            } else if showAccess {
                VaultAccessView(isSetup: needsSetup, onAuthorized: { finishUnlock() },
                    onCalculator: { showAccess = false })
            } else if isCameraOnly {
                VaultView(cameraOnly: true, onLock: lock)
            } else if isUnlocked {
                VaultView(onLock: lock)
            } else {
                CalculatorView(onUnlock: unlock,
                               vaultEntryEnabled: !needsSetup && !VaultLifecycle.shared.isBruteForceLocked)
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
        #if DEBUG && targetEnvironment(simulator)
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--test-calculator") && args.contains("--preview-radar") {
                showRadarPreview = true
            }
        }
        .sheet(isPresented: $showRadarPreview) {
            RestrictedPlacesRadarView()
                .onAppear { RestrictedPlacesMonitor.shared.seedRadarPreview() }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        #endif
    }

    private func refreshAccess(initial: Bool = false) {
        if VaultLifecycle.shared.isBruteForceLocked {
            needsSetup = false
            accessError = nil
            accessChecked = true
            showAccess = false
            return
        }
        guard !VaultLifecycle.shared.isErasing else {
            needsSetup = false; accessChecked = false; showAccess = false
            return
        }
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--test-calculator"), !calculatorFixturePrepared {
            guard UIApplication.shared.isProtectedDataAvailable else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { refreshAccess(initial: initial) }
                return
            }
            do {
                try prepareCalculatorFixture()
                calculatorFixturePrepared = true
            } catch {
                accessError = "Не удалось подготовить UI-тест: \(error.localizedDescription)"
                accessChecked = true; showAccess = true
                return
            }
        }
        #endif
        do {
            defer { if !isUnlocked { CryptoManager.lockVault() } }
            try MainPINChangeTransaction.application.recoverIfNeeded()
        } catch {
            // An interrupted PIN change is not a fresh install. Keep both
            // encrypted material and its recovery journal until retry succeeds.
            accessError = "Не удалось завершить смену кода: \(error.localizedDescription). Повторите попытку."
            needsSetup = false; accessChecked = true
            if !initial { showAccess = true }
            return
        }
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
    #if DEBUG && targetEnvironment(simulator)
    private func prepareCalculatorFixture() throws {
        try CryptoManager.destroyKey()
        guard CryptoManager.encrypt(Data("ui-test-key".utf8)) != nil else {
            throw CocoaError(.fileWriteNoPermission)
        }
        if ProcessInfo.processInfo.arguments.contains("--test-legacy-avatar") {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let avatar = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30), format: format).image { _ in
                UIColor.orange.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 40, height: 30))
            }
            guard let jpeg = avatar.jpegData(compressionQuality: 0.8), let encrypted = CryptoManager.encrypt(jpeg) else {
                throw CocoaError(.fileWriteUnknown)
            }
            UserDefaults.standard.set(encrypted, forKey: "protected.userAvatar")
        }
        try KeychainCodeStore.write("1357", for: "mainCode")
        try CryptoManager.bindPIN("1357")
        if ProcessInfo.processInfo.arguments.contains("--test-action-button-disable") {
            SettingsStore.shared.actionButtonMode = .disable
            try KeychainCodeStore.writeActionToken("ui-test-permanent-disable")
        }
        if ProcessInfo.processInfo.arguments.contains("--test-settings") {
            InactivityTimerManager.shared.disable()
            SettingsStore.shared.failedPasswordWipeLimit = 0
            SettingsStore.shared.resetPasswordFailureState()
        }
        CryptoManager.lockVault()
    }
    #endif
    private var isUITestFixture: Bool {
        #if DEBUG && targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--test-calculator")
        #else
        return false
        #endif
    }
    private func unlock(_ pin: String) {
        guard !VaultLifecycle.shared.isBruteForceLocked else { return }
        guard !VaultLifecycle.shared.blocksUI,
              (try? VaultGate.shared.withAccess { true }) == true else { return }
        if (try? CryptoManager.unlock(withPIN: pin)) == nil {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--test-calculator") {
                accessError = "Не удалось открыть ключ подготовленного UI-теста."
                showAccess = true
            }
            #endif
            return
        }
        finishUnlock()
    }
    private func finishUnlock() {
        guard !VaultLifecycle.shared.isBruteForceLocked else { return }
        guard !VaultLifecycle.shared.blocksUI,
              (try? VaultGate.shared.withAccess { true }) == true else { return }
        // Separate an expired/tampered marker from a temporary write failure.
        // A confirmed expiry (and the existing fail-closed corrupt-marker
        // policy) is destructive; a later marker-write failure is retryable.
        let inactivity = InactivityTimerManager.shared
        if let limit = inactivity.activeLimitHours,
           inactivity.shouldWipeData(limitHours: limit) {
            VaultLifecycle.shared.erase(.reset)
            return
        }
        guard inactivity.recordActivity() else {
            CryptoManager.lockVault()
            isUnlocked = false
            accessError = inactivity.lastError ?? "Не удалось обновить контроль времени. Повторите попытку."
            showAccess = true
            return
        }
        let wasSetup = needsSetup
        SettingsStore.shared.reloadProtectedPreferences()
        FileStorageManager.shared.refreshEventDistanceAnchor()
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
            // A separate single-frame event makes selection/deletion tests
            // prove that neighbouring events are neither merged nor removed.
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400), format: format).image { _ in
                UIColor.darkGray.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 300, height: 400))
                UIColor.systemTeal.setFill(); UIRectFill(CGRect(x: 10, y: 10, width: 280, height: 380))
            }
            let context = CaptureContext(eventID: UUID(uuidString: "22345678-1234-1234-1234-123456789012")!,
                folder: "0.5", expectedCount: 1, index: 1, eventNumber: 2, generation: VaultGate.shared.generation)
            precondition(storage.save(image: image, context: context) != nil, "UI test neighbouring event could not be saved")
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
