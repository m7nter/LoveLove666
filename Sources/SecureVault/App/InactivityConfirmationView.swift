import SwiftUI

struct InactivityConfirmationView: View {
    let hours: Int
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var remaining = 15
    @State private var timer: Timer?

    private var intervalText: String {
        switch hours {
        case 24: return "24 часа"
        case 48: return "48 часов"
        case 72: return "72 часа"
        case 168: return "7 дней"
        default: return "выбранный интервал"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("⚠️ ВНИМАНИЕ! КРИТИЧЕСКИЙ РЕЖИМ БЕЗОПАСНОСТИ")
                        .font(.title3.bold())
                        .foregroundStyle(.red)
                    Text("Вы активируете функцию автоматического самоуничтожения (Dead Man's Switch). Если приложение не будет запущено и разблокировано в течение выбранного времени (например, устройство выключено, вы задержаны, находитесь вне зоны связи или забыли зайти), абсолютно все данные внутри хранилища, включая фотографии и файлы, будут БЕЗВОЗВРАТНО УНИЧТОЖЕНЫ на уровне зашифрованных контейнеров.\n\nВосстановить информацию после срабатывания таймера технически невозможно. Никакие резервные копии или бэкапы предусмотрены не будут.\n\nНе играйте с системным временем. Откат часов и несоответствие времени работы устройства обнаруживаются автоматически и могут привести к немедленному уничтожению данных.")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Интервал: \(intervalText). После активации приложение должно быть запущено и разблокировано до истечения этого интервала.")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Button {
                        onConfirm()
                        dismiss()
                    } label: {
                        Text(remaining > 0 ? "Активация будет доступна через \(remaining) сек…" : "Я понимаю риски и активировать")
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
