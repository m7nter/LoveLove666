import SwiftUI

struct WelcomeGuidePromptView: View {
    let onGuide: () -> Void
    let onExperienced: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.orange, .yellow.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 82, height: 82)
                    .shadow(color: .orange.opacity(0.35), radius: 18, y: 8)
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.82))
            }
            VStack(spacing: 9) {
                Text("Добро пожаловать")
                    .font(.system(size: 29, weight: .bold, design: .rounded))
                Text("Выберите удобный старт. Руководство можно открыть позже в настройках.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 12) {
                Button(action: onGuide) {
                    HStack(spacing: 14) {
                        Image(systemName: "book.fill")
                            .font(.title3.weight(.bold))
                            .frame(width: 42, height: 42)
                            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Я не знаю, как пользоваться")
                                .font(.headline)
                            Text("Открыть короткое руководство")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.78))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .background(LinearGradient(colors: [.orange, .orange.opacity(0.78)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .orange.opacity(0.25), radius: 14, y: 7)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("welcome.openGuide")

                Button(action: onExperienced) {
                    HStack(spacing: 14) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.orange)
                            .frame(width: 42, height: 42)
                            .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Я уже опытный")
                                .font(.headline)
                            Text("Перейти к калькулятору")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.58))
                        }
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.14), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("welcome.skipGuide")
            }
            Text("Оба варианта открывают приложение сразу; выбор можно изменить в любой момент.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 12)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Color(red: 0.08, green: 0.07, blue: 0.06), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea())
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
                        Text("Приложение выглядит и работает как обычный калькулятор. Стандартный режим поддерживает скобки, проценты, смену знака, повтор операции и вывод «Не определено» для деления на ноль. Научный режим открывает степени, корни, функции, память, радианы/градусы и дополнительные операции. История вычислений открывается кнопкой с часами и содержит реальные выполненные расчёты.")
                    }
                    GuideBlock(icon: "1.circle.fill", title: "Первый запуск и коды") {
                        Text("При первом открытии создайте основной код из 4–8 цифр и подтвердите его. Для входа в хранилище наберите этот код на калькуляторе и нажмите «=». После полного сброса или команды стирания приложение снова предложит создать новый код. Код хранилища и пароль-камикадзе настраиваются отдельно в разделе «Безопасность».")
                    }
                    GuideBlock(icon: "arrow.left.arrow.right", title: "Конвертация и курсы") {
                        Text("В режиме конвертации можно пересчитывать валюты и единицы. Курсы валют берутся из Yahoo! Finance и сохраняются с датой кэша; при отсутствии сети используется последний сохранённый курс. Валюты выбираются через поиск и меню категорий.")
                    }
                    GuideBlock(icon: "lock.fill", title: "Доступ к хранилищу") {
                        Text("Хранилище открывается скрытым способом через калькулятор. Не сообщайте личный код другим людям. После полного сброса приложение предложит создать новый код. Фотографии и заметки хранятся в зашифрованном виде.")
                    }
                    GuideBlock(icon: "camera.fill", title: "Камера") {
                        Text("Каждый снимок может сохранить координаты, точность GPS и азимут. Цвет индикатора рядом с координатами показывает качество GPS. Если включена защита точности, при плохом сигнале кнопка съёмки блокируется. Доступны звук затвора, вспышка, масштаб 0,5–2×, съёмка кнопками громкости, прицел и чёрный экран с жестом двумя тройными касаниями.")
                    }
                    GuideBlock(icon: "square.stack.3d.up.fill", title: "События и папки") {
                        Text("Несколько кадров можно объединить в одно событие. Фотографии события остаются отдельными файлами, но открываются одной серией. Папки режимов помогают распределять съёмки по рабочим категориям.")
                    }
                    GuideBlock(icon: "pencil.and.outline", title: "Редактор") {
                        Text("В редакторе доступны стрелки, овалы, текст и размытие. Один палец рисует или перемещает объект, двумя пальцами можно менять масштаб и вращать текст. Для текста можно выбрать шрифт, цвет, фон и шаблон. Изображение сохраняет исходные пропорции 4:3; подпись и шаблон добавляются отдельным нижним блоком при экспорте.")
                    }
                    GuideBlock(icon: "square.and.arrow.up.fill", title: "Экспорт") {
                        Text("Фотографии можно выгружать отдельными файлами или ZIP-архивом. Для архива можно выбрать все метаданные, только координаты или отдельные поля. При выгрузке отдельными файлами открывается системное меню «Поделиться»: Telegram может отправить подпись отдельным сообщением или разделить фотографии — это зависит от его Share Extension. Координаты берутся с первого фото события и форматируются с шестью знаками после запятой.")
                    }
                    GuideBlock(icon: "note.text", title: "Заметки и шаблоны") {
                        Text("Дневник позволяет хранить текстовые записи внутри зашифрованного хранилища. Шаблоны подписей ускоряют редактор; их можно создавать, выбирать и удалять в настройках редактора.")
                    }
                    GuideBlock(icon: "location.viewfinder", title: "Контроль запретных мест OSM") {
                        Text("Приложение проверяет ближайшие территории по OpenStreetMap. Для детских площадок, садов, школ, спортобъектов и государственных категорий можно отдельно включать типы и задавать расстояния. Есть автоматический, онлайн- и офлайн-режимы. При отсутствии свежих данных или плохой точности GPS съёмка блокируется, чтобы не дать ложное разрешение. На экране показываются до трёх ближайших категорий и расстояния. После изменения офлайн-базы нужно обновить объекты зон.")
                    }
                    GuideBlock(icon: "checkmark.shield.fill", title: "Если съёмка заблокирована") {
                        Text("Откройте камеру и прочитайте причину над кнопкой съёмки. Частые причины: GPS ещё не получил свежую точку, погрешность выше заданного порога, онлайн-сервер OSM не ответил, офлайн-база не покрывает место или найдена запретная территория. В онлайн-режиме нажмите «Проверить сейчас» в настройках и дождитесь успешного ответа. В офлайн-режиме сначала завершите загрузку карты и объектов зон.")
                    }
                    GuideBlock(icon: "map.fill", title: "Офлайн-карты") {
                        Text("Регион можно скачать заранее. Карта и база запретных зон загружаются отдельно. После полной загрузки проверка работает без интернета в пределах сохранённой области.")
                    }
                    GuideBlock(icon: "button.programmable", title: "Action Button") {
                        Text("В настройках можно назначить открытие камеры, удаление фотографий или полный сброс. Разрушающие действия требуют особой осторожности: удалённые данные не восстанавливаются, а уже отправленные копии в других приложениях не удаляются.")
                    }
                    GuideBlock(icon: "gearshape.fill", title: "Настройки") {
                        Text("Все функции можно включать и отключать отдельно: GPS-защиту, минимальную дистанцию между событиями, звук и режимы камеры, шаблоны, экспорт, карты, автоблокировку и пароли. В разделе безопасности есть автоматическое уничтожение при неактивности: оно требует 15-секундного подтверждения, хранит контроль времени в Keychain и обнаруживает откат часов. Руководство можно открыть в любой момент из настроек.")
                    }
                    GuideBlock(icon: "exclamationmark.shield.fill", title: "Автоматическое уничтожение") {
                        Text("Dead Man's Switch уничтожает зашифрованное хранилище, если приложение не запущено и не разблокировано в выбранный срок: 24, 48, 72 часа или 7 дней. После срабатывания восстановление невозможно. Не меняйте системное время: проверка сопоставляет обычные часы с монотонным аптаймом устройства, и подозрительный откат может немедленно запустить сброс.")
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
