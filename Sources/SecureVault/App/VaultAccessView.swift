import SwiftUI

// Setup is a root screen, so it cannot be lost during sheet presentation or reset.
struct VaultAccessView: View {
    let isSetup: Bool
    let onAuthorized: () -> Void
    let onCalculator: () -> Void
    @State private var code = ""
    @State private var confirmation = ""
    @State private var error: String?
    @StateObject private var calculator = CalculatorViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(isSetup ? "Создайте личный код" : "Вход в хранилище")
                        .font(.title2.bold())
                    Text(isSetup
                         ? "Придумайте код из 4–8 цифр. После сохранения хранилище откроется сразу. Затем вход: AC → ваш код → =."
                         : "Введите свой личный код.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section(isSetup ? "Новый код" : "Ваш код") {
                    SecureField("Код из 4–8 цифр", text: $code)
                        .keyboardType(.numberPad).textContentType(.password)
                        .accessibilityIdentifier("access.code")
                    if isSetup {
                        SecureField("Повторите код", text: $confirmation)
                            .keyboardType(.numberPad).textContentType(.password)
                            .accessibilityIdentifier("access.confirmation")
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button(isSetup ? "Создать и открыть хранилище" : "Открыть хранилище", action: submit)
                        .accessibilityIdentifier("access.submit")
                }
            }
            .navigationTitle("Настройка доступа")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Калькулятор", action: onCalculator)
                }
            }
            .tint(.orange)
        }
        .preferredColorScheme(.dark)
    }

    private func submit() {
        guard !VaultLifecycle.shared.blocksUI else { return }
        guard (4...8).contains(code.count), code.allSatisfy({ "0123456789".contains($0) }) else {
            error = "Введите от 4 до 8 цифр."; return
        }
        if isSetup {
            guard code == confirmation else { error = "Коды не совпадают."; return }
            guard code != "2026", code != SettingsStore.shared.kamikazeCode else {
                error = "Выберите другой личный код."; return
            }
            do {
                try VaultGate.shared.withAccess {
                    // Check both persistent code and encryption availability before opening.
                    guard CryptoManager.encrypt(Data("setup-check".utf8)) != nil else {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    try KeychainCodeStore.write(code, for: "mainCode")
                    guard try KeychainCodeStore.readChecked("mainCode") == code else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    try CryptoManager.bindPIN(code)
                }
                onAuthorized()
            } catch {
                self.error = "Не удалось создать хранилище: \(error.localizedDescription) (\((error as NSError).code))."
            }
        } else {
            // The explicit sign-in and hidden calculator entry share throttling.
            calculator.tap("AC")
            for digit in code { calculator.tap(String(digit)) }
            calculator.tap("=")
            if calculator.shouldUnlock {
                do {
                    try CryptoManager.unlock(withPIN: code)
                    onAuthorized()
                } catch {
                    self.error = "Код верный, но не удалось открыть ключ шифрования: \(error.localizedDescription)"
                }
            }
            else { error = "Код не подошёл или действует минутная пауза после нескольких попыток." }
        }
    }
}

struct VaultRecoveryView: View {
    @ObservedObject var lifecycle: VaultLifecycle
    let onCalculator: () -> Void
    var body: some View {
        VStack(spacing: 24) {
            if lifecycle.isErasing {
                ProgressView().tint(.orange)
                Text("Подготовка нового хранилища") .font(.title2.bold())
                Text("Завершаем удаление старых данных. Затем вы сможете задать новый код.")
            } else {
                Image(systemName: "arrow.clockwise.circle").font(.system(size: 48)).foregroundStyle(.orange)
                Text("Завершите сброс") .font(.title2.bold())
                Text(lifecycle.lastError ?? "Обнаружена блокировка из старой версии. После очистки откроется настройка нового кода.")
                Button("Повторить очистку") { lifecycle.erase(.reset) }.buttonStyle(.borderedProminent).tint(.orange)
            }
            Button("Калькулятор", action: onCalculator).tint(.orange)
        }
        .multilineTextAlignment(.center).padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea()).preferredColorScheme(.dark)
    }
}
