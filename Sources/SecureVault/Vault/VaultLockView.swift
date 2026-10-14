import SwiftUI

struct VaultLockView: View {
    let onUnlock: () -> Void
    let onCancel: () -> Void

    @State private var input: String = ""
    @State private var error: Bool = false
    private let attemptsKey = "vaultFolderPinAttempts"
    private let cooldownKey = "vaultFolderPinCooldownUntil"

    private let buttons: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["⌫", "0", "✓"]
    ]

    var body: some View {
        ZStack {
            Color(hex: "#1C1C1E").ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.orange)

                Text("Введите пароль хранилища")
                    .font(.headline)
                    .foregroundColor(.white)

                // Точки
                HStack(spacing: 16) {
                    ForEach(0..<4, id: \.self) { i in
                        Circle()
                            .fill(i < input.count ? Color.orange : Color.gray.opacity(0.4))
                            .frame(width: 14, height: 14)
                    }
                }

                if error {
                    Text("Неверный пароль")
                        .foregroundColor(.red)
                        .font(.caption)
                }

                // Клавиатура
                VStack(spacing: 16) {
                    ForEach(buttons, id: \.self) { row in
                        HStack(spacing: 16) {
                            ForEach(row, id: \.self) { btn in
                                Button {
                                    handleTap(btn)
                                } label: {
                                    Text(btn)
                                        .font(.system(size: 28, weight: .regular))
                                        .foregroundColor(.white)
                                        .frame(width: 80, height: 80)
                                        .background(
                                            btn == "✓" ? Color.orange :
                                            btn == "⌫" ? Color(hex: "#2C2C2E") :
                                            Color(hex: "#2C2C2E")
                                        )
                                        .clipShape(Circle())
                                }
                            }
                        }
                    }
                }

                Spacer()

                Button("Отмена") { onCancel() }
                    .foregroundColor(.gray)
                    .padding(.bottom, 32)
            }
        }
    }

    private func handleTap(_ btn: String) {
        error = false
        switch btn {
        case "⌫":
            if !input.isEmpty { input.removeLast() }
        case "✓":
            checkCode()
        default:
            if input.count < 8 { input += btn }
            // Автопроверка если пароль введён полностью
            if input.count == SettingsStore.shared.vaultCode.count {
                checkCode()
            }
        }
    }

    private func checkCode() {
        let store = SettingsStore.shared
        guard Date().timeIntervalSince1970 >= UserDefaults.standard.double(forKey: cooldownKey) else {
            error = true
            input = ""
            return
        }
        let code = store.vaultCode
        if !code.isEmpty && input == code {
            UserDefaults.standard.removeObject(forKey: attemptsKey)
            UserDefaults.standard.removeObject(forKey: cooldownKey)
            onUnlock()
        } else {
            error = true
            input = ""
            let now = Date().timeIntervalSince1970
            var attempts = (UserDefaults.standard.array(forKey: attemptsKey) as? [TimeInterval] ?? [])
                .filter { now - $0 < 60 }
            attempts.append(now)
            if attempts.count >= 6 {
                UserDefaults.standard.set(now + 60, forKey: cooldownKey)
                UserDefaults.standard.removeObject(forKey: attemptsKey)
            } else {
                UserDefaults.standard.set(attempts, forKey: attemptsKey)
            }
        }
    }
}
