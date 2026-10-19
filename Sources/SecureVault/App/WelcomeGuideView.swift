import SwiftUI

struct WelcomeGuidePromptView: View {
    let onGuide: () -> Void
    let onExperienced: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 42))
                .foregroundStyle(.orange)
            Text("Добро пожаловать")
                .font(.title2.bold())
            Text("Хотите быстро ознакомиться с возможностями приложения и правилами работы с хранилищем?")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(spacing: 12) {
                Button("Я не знаю как пользоваться") { onGuide() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .frame(maxWidth: .infinity)
                Button("Я уже опытный") { onExperienced() }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(true)
    }
}

struct WelcomeGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GuideBlock(icon: "plus.slash.minus", title: "Калькулятор") {
                        Text("Приложение выглядит и работает как обычный калькулятор. Стандартные расчёты доступны сразу. Научный режим открывает степени, корни, функции, память и дополнительные операции. История вычислений открывается кнопкой с часами.")
                    }
                    GuideBlock(icon: "lock.fill", title: "Доступ к хранилищу") {
                        Text("Хранилище открывается скрытым способом через калькулятор. Не сообщайте личный код другим людям. После полного сброса приложение предложит создать новый код. Фотографии и заметки хранятся в зашифрованном виде.")
                    }
                    GuideBlock(icon: "camera.fill", title: "Камера") {
                        Text("Каждый снимок может сохранить координаты, точность GPS и азимут. Цвет индикатора рядом с координатами показывает качество GPS. Если включена защита точности, при плохом сигнале кнопка съёмки блокируется.")
                    }
                    GuideBlock(icon: "square.stack.3d.up.fill", title: "События и папки") {
                        Text("Несколько кадров можно объединить в одно событие. Фотографии события остаются отдельными файлами, но открываются одной серией. Папки режимов помогают распределять съёмки по рабочим категориям.")
                    }
                    GuideBlock(icon: "pencil.and.outline", title: "Редактор") {
                        Text("В редакторе доступны стрелки, овалы, текст и размытие. Текст можно перемещать одним пальцем, изменять двумя пальцами и вращать. Для текста можно выбрать цвет и фон.")
                    }
                    GuideBlock(icon: "square.and.arrow.up.fill", title: "Экспорт") {
                        Text("Фотографии можно выгружать отдельными файлами или ZIP-архивом. Для архива можно выбрать все метаданные, только координаты или отдельные поля. При включённой настройке координаты формируются отдельным сообщением для передачи вместе со снимками.")
                    }
                    GuideBlock(icon: "location.viewfinder", title: "Контроль запретных мест OSM") {
                        Text("Приложение проверяет ближайшие территории по OpenStreetMap. Для детских и государственных объектов можно отдельно включать категории и задавать расстояния. Есть онлайн- и офлайн-режимы. При отсутствии свежих данных или плохой точности GPS съёмка блокируется, чтобы не дать ложное разрешение.")
                    }
                    GuideBlock(icon: "map.fill", title: "Офлайн-карты") {
                        Text("Регион можно скачать заранее. Карта и база запретных зон загружаются отдельно. После полной загрузки проверка работает без интернета в пределах сохранённой области.")
                    }
                    GuideBlock(icon: "button.programmable", title: "Action Button") {
                        Text("В настройках можно назначить открытие камеры, удаление фотографий или полный сброс. Разрушающие действия требуют особой осторожности: удалённые данные не восстанавливаются, а уже отправленные копии в других приложениях не удаляются.")
                    }
                    GuideBlock(icon: "gearshape.fill", title: "Настройки") {
                        Text("Все функции можно включать и отключать отдельно: GPS-защиту, минимальную дистанцию между событиями, звук и режимы камеры, шаблоны, экспорт, карты, автоблокировку и пароли.")
                    }
                }
                .padding(20)
            }
            .navigationTitle("Руководство")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }
                        .foregroundColor(.orange)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct GuideBlock<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.orange)
            content()
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
}
