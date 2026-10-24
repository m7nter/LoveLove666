import SwiftUI

struct BruteForceConfirmationView: View {
    let attempts: Int
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var remaining = 15
    @State private var timer: Timer?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("⚠️ ВНИМАНИЕ! ЗАЩИТА ОТ ПЕРЕБОРА ПАРОЛЯ")
                        .font(.title3.bold())
                        .foregroundStyle(.red)
                    Text("После (attempts) неверных попыток ввода пароля приложение автоматически запустит полное уничтожение хранилища. Будут безвозвратно удалены фотографии, файлы, заметки, настройки и ключи шифрования. Восстановить данные технически невозможно.")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Будьте особенно внимательны: ошибочный ввод, забытый пароль или случайные нажатия могут привести к потере всех данных. Резервные копии для восстановления не предусмотрены. Не пытайтесь обходить защиту изменением системного времени.")
                        .font(.body)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        onConfirm()
                        dismiss()
                    } label: {
                        Text(remaining > 0 ? "Активация будет доступна через (remaining) сек…" : "Я понимаю риски и включить защиту")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(remaining > 0)
                    Button("Отмена") { dismiss() }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.bordered)
                }
                .padding(22)
            }
            .navigationTitle("Подтверждение безопасности")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(true)
        .onAppear { startCountdown() }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    private func startCountdown() {
        remaining = 15
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            if remaining > 0 { remaining -= 1 }
            if remaining <= 0 { timer.invalidate() }
        }
    }
}
