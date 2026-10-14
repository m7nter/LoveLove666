import SwiftUI

struct SettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @Environment(\.dismiss) var dismiss
    @State private var showPicker = false
    @State private var showChangeMain = false
    @State private var showChangeVault = false
    @State private var showChangeKamikaze = false
    @State private var showActionButtonWarning = false
    @State private var pendingActionMode: ActionButtonMode = .off
    @State private var newMode = ""

    var body: some View {
        NavigationView {
            List {
                Section("Нумерация фото") {
                    Picker("Номера", selection: $store.numberingMode) {
                        Text("Выключена").tag("off")
                        Text("За день").tag("daily")
                        Text("Общая").tag("total")
                        Text("За день и общая").tag("both")
                    }
                    Text("Номера отображаются под снимками и в именах экспортируемых файлов. Удаление фото не сбрасывает счётчик.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section("Папки режимов") {
                    Toggle("Распределять новые фото по режимам", isOn: $store.foldersEnabled)
                    if store.foldersEnabled {
                        Picker("Текущий режим", selection: $store.activeWorkMode) {
                            ForEach(store.workModes, id: \.self) { Text($0).tag($0) }
                        }
                        HStack {
                            TextField("Новый режим, например 3", text: $newMode)
                            Button("Добавить") {
                                let name = newMode.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard FileStorageManager.validFolder(name), name != "Без режима",
                                      !store.workModes.contains(name) else { return }
                                store.workModes.append(name)
                                store.activeWorkMode = name
                                newMode = ""
                            }
                        }
                    }
                    Text("Режим — метка папки, а не увеличение объектива. Уже снятые фото остаются в своих папках; их можно переместить из хранилища.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section("События") {
                    Stepper("Фото на событие: \(store.photosPerEvent)", value: $store.photosPerEvent, in: 1...20)
                    Text("Каждый кадр снимается отдельно. Серия объединяется в одно событие и одну папку. Настройка применяется к следующему событию; незавершённую серию можно закончить вручную.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section("Чёрный экран") {
                    Toggle("Два касания тремя пальцами", isOn: $store.blackScreenEnabled)
                    Text("Жест в камере скрывает экран; повторный жест возвращает его. Геолокация продолжает обновляться, пока приложение активно. Это не блокировка iPhone; GPS зависит от условий приёма, режим расходует батарею.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section("Пометки на фото") {
                    Picker("Цвет стрелок, овалов и текста", selection: $store.annotationColor) {
                        Text("Красный").tag("red")
                        Text("Жёлтый").tag("yellow")
                        Text("Белый").tag("white")
                        Text("Чёрный").tag("black")
                    }
                }
                Section("Фото на снимках") {
                    HStack(spacing: 16) {
                        if let img = store.avatarImage {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 64, height: 64)
                                .overlay(
                                    Image(systemName: "person.fill")
                                        .foregroundColor(.gray)
                                )
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Button("Выбрать фото") { showPicker = true }
                                .foregroundColor(.orange)
                            if store.avatarImage != nil {
                                Button("Удалить") { store.avatarImage = nil }
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Прицел") {
                    Toggle("Показывать перекрестие", isOn: $store.showCrosshair)
                        .tint(.orange)
                    Toggle("Перекрестие на фото", isOn: $store.crosshairOnPhoto)
                        .tint(.orange)
                    if store.showCrosshair {
                        HStack {
                            Text("Цвет")
                            Spacer()
                            ForEach(["white", "red", "green", "yellow"], id: \.self) { colorName in
                                Circle()
                                    .fill(color(for: colorName))
                                    .frame(width: 28, height: 28)
                                    .overlay(
                                        Circle().stroke(Color.white,
                                                        lineWidth: store.crosshairColor == colorName ? 2 : 0)
                                    )
                                    .onTapGesture { store.crosshairColor = colorName }
                            }
                        }
                    }
                }

                Section("Точность GPS") {
                    Toggle("Защита от погрешности", isOn: $store.accuracyProtectionEnabled)
                        .tint(.orange)

                    if store.accuracyProtectionEnabled {
                        Picker("Максимальная погрешность", selection: $store.accuracyThreshold) {
                            Text("5 м").tag(5)
                            Text("10 м").tag(10)
                            Text("15 м").tag(15)
                            Text("20 м").tag(20)
                            Text("30 м").tag(30)
                            Text("50 м").tag(50)
                        }
                        Text("Кнопка съёмки будет заблокирована, если погрешность координат превышает выбранное значение")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Дистанция между фото") {
                    Toggle("Показывать дистанцию от последнего фото", isOn: $store.distanceTrackingEnabled)
                        .tint(.orange)

                    if store.distanceTrackingEnabled {
                        Picker("Минимально допустимая дистанция", selection: $store.minDistanceThreshold) {
                            Text("5 м").tag(5)
                            Text("10 м").tag(10)
                            Text("15 м").tag(15)
                            Text("20 м").tag(20)
                            Text("30 м").tag(30)
                            Text("50 м").tag(50)
                            Text("100 м").tag(100)
                        }
                        Text("На экране камеры появится дистанция от последнего сделанного фото. Если она меньше выбранного значения — сработает предупреждение")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Action Button") {
                    Picker("Действие", selection: Binding(
                        get: { store.actionButtonMode },
                        set: { mode in
                            if mode == .off { store.actionButtonMode = .off }
                            else { pendingActionMode = mode; showActionButtonWarning = true }
                        }
                    )) {
                        ForEach(ActionButtonMode.allCases) { Text($0.title).tag($0) }
                    }
                    Text(store.actionButtonMode.detail).font(.caption).foregroundColor(.secondary)
                    if store.actionButtonMode != .off {
                        Text("В «Командах» создайте действие «Открыть URL» с адресом ниже и назначьте эту команду на Action Button в настройках iPhone.")
                            .font(.caption).foregroundColor(.secondary)
                        Text(store.actionButtonURL).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Скопировать адрес команды") { UIPasteboard.general.string = store.actionButtonURL }
                        if store.actionButtonMode.destructive {
                            Text("Запуск этой команды удаляет данные сразу, без повторного подтверждения. Храните адрес команды приватно. Старый адрес запуска камеры данные не удаляет.")
                                .font(.caption).foregroundColor(.red)
                        }
                    }
                    if let securityError = store.securityError {
                        Text(securityError).font(.caption).foregroundColor(.red)
                    }
                }

                Section("Съёмка") {
                    Toggle("Снимать кнопками громкости", isOn: $store.volumeButtonCaptureEnabled)
                        .tint(.orange)
                }

                Section("Экспорт фото") {
                    Toggle("Впечатывать заметку на фото", isOn: $store.notesOnExport)
                    Text("При выгрузке к изображению снизу добавляется полная текстовая заметка. Работает для ZIP и отдельных файлов; оригинал в хранилище не меняется.")
                        .font(.caption).foregroundColor(.secondary)
                    Picker("Способ выгрузки", selection: $store.exportAsZip) {
                        Text("ZIP-архивом").tag(true)
                        Text("Отдельными файлами").tag(false)
                    }
                    .pickerStyle(.segmented)
                    Text(store.exportAsZip
                         ? "Фото за день упаковываются в один ZIP-архив вместе с файлом метаданных (координаты, дата)"
                         : "Каждое фото за день отправляется отдельным файлом без метаданных в архиве")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Карта") {
                    Toggle("Объединять близкие метки", isOn: $store.clusterMapPins)
                        .tint(.orange)
                    Text("Если фото сделаны рядом друг с другом, метки на карте будут объединяться в один кружок с числом снимков. При увеличении масштаба метки разделяются")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Безопасность") {
                    Toggle("Блокировать при сворачивании", isOn: $store.lockOnBackground)
                        .tint(.orange)

                    if !store.lockOnBackground {
                        Picker("Автоблокировка", selection: $store.autoLockTimeout) {
                            Text("Выключено").tag(0)
                            Text("1 минуту").tag(60)
                            Text("5 минут").tag(300)
                            Text("15 минут").tag(900)
                            Text("30 минут").tag(1800)
                        }
                    }

                    Button("Изменить основной пароль") { showChangeMain = true }
                        .foregroundColor(.orange)
                    if store.mainCode == "2026" {
                        Text("Используется стандартный код 2026. Смените его перед работой с чувствительными материалами.")
                            .font(.caption).foregroundColor(.red)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Пароль хранилища")
                            Text(store.vaultCodeEnabled ? "Включён" : "Выключен")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { store.vaultCodeEnabled },
                            set: {
                                if $0 && store.vaultCode.isEmpty { showChangeVault = true }
                                else { store.vaultCodeEnabled = $0 }
                            }
                        )).tint(.orange).labelsHidden()
                    }
                    if store.vaultCodeEnabled {
                        Button("Изменить пароль хранилища") { showChangeVault = true }
                            .foregroundColor(.orange)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Пароль-камикадзе")
                            Text(store.kamikazeCodeEnabled ? "При вводе удалит все фото" : "Выключен")
                                .font(.caption)
                                .foregroundColor(store.kamikazeCodeEnabled ? .red : .secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { store.kamikazeCodeEnabled },
                            set: {
                                if $0 && store.kamikazeCode.isEmpty { showChangeKamikaze = true }
                                else { store.kamikazeCodeEnabled = $0 }
                            }
                        )).tint(.red).labelsHidden()
                    }
                    if store.kamikazeCodeEnabled {
                        Button("Изменить пароль-камикадзе") { showChangeKamikaze = true }
                            .foregroundColor(.red)
                    }
                }

                Section("Подсказка") {
                    Text("Фото отображается в правом нижнем углу каждого снимка")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }.foregroundColor(.orange)
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            ImagePicker { img in store.avatarImage = img }
        }
        .sheet(isPresented: $showChangeMain) {
            ChangeCodeView(title: "Основной пароль", currentCode: store.mainCode, requireCurrent: true,
                           forbiddenCodes: ["2026"] + (store.kamikazeCodeEnabled ? [store.kamikazeCode] : [])) {
                store.mainCode = $0
                return store.securityError == nil
            }
        }
        .sheet(isPresented: $showChangeVault) {
            ChangeCodeView(title: "Пароль хранилища", currentCode: store.vaultCode, requireCurrent: !store.vaultCode.isEmpty) {
                store.vaultCode = $0
                guard store.securityError == nil else { return false }
                store.vaultCodeEnabled = true
                return true
            }
        }
        .sheet(isPresented: $showChangeKamikaze) {
            ChangeCodeView(title: "Пароль-камикадзе", currentCode: store.kamikazeCode, requireCurrent: !store.kamikazeCode.isEmpty,
                           forbiddenCodes: [store.mainCode]) {
                store.kamikazeCode = $0
                guard store.securityError == nil else { return false }
                store.kamikazeCodeEnabled = true
                return true
            }
        }
        .alert("Настроить Action Button?", isPresented: $showActionButtonWarning) {
            Button("Включить", role: pendingActionMode.destructive ? .destructive : nil) {
                store.actionButtonMode = pendingActionMode
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(pendingActionMode.detail + (pendingActionMode.destructive ? "\n\nПосле настройки команда срабатывает без повторного подтверждения. Уже переданные другим приложениям файлы и внешние резервные копии не удаляются." : ""))
        }
    }

    private func color(for name: String) -> Color {
        switch name {
        case "red": return .red
        case "green": return .green
        case "yellow": return .yellow
        default: return .white
        }
    }
}

struct ChangeCodeView: View {
    let title: String
    let currentCode: String
    let requireCurrent: Bool
    var forbiddenCodes: [String] = []
    var allowCancel = true
    let onSave: (String) -> Bool

    @Environment(\.dismiss) var dismiss
    @State private var oldCode = ""
    @State private var newCode = ""
    @State private var confirmCode = ""
    @State private var error = ""

    var body: some View {
        NavigationView {
            Form {
                if !allowCancel {
                    Section {
                        Text("Создайте код из 4–8 цифр. В дальнейшем наберите его на калькуляторе и нажмите «=», чтобы открыть хранилище.")
                            .font(.subheadline)
                    }
                }
                if requireCurrent {
                    Section("Текущий пароль") {
                        SecureField("Введите текущий пароль", text: $oldCode)
                            .keyboardType(.numberPad)
                    }
                }
                Section("Новый пароль") {
                    SecureField("Введите новый пароль", text: $newCode)
                        .keyboardType(.numberPad)
                    SecureField("Повторите новый пароль", text: $confirmCode)
                        .keyboardType(.numberPad)
                }
                if !error.isEmpty {
                    Section {
                        Text(error).foregroundColor(.red).font(.caption)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if allowCancel {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Отмена") { dismiss() }.foregroundColor(.red)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Сохранить") { save() }.foregroundColor(.orange)
                }
            }
        }
        .interactiveDismissDisabled(!allowCancel)
    }

    private func save() {
        if requireCurrent && oldCode != currentCode {
            error = "Неверный текущий пароль"; return
        }
        if !(4...8).contains(newCode.count) || !newCode.allSatisfy({ "0123456789".contains($0) }) {
            error = "Пароль должен содержать от 4 до 8 цифр"; return
        }
        if forbiddenCodes.contains(newCode) {
            error = "Этот код уже используется. Выберите другой."; return
        }
        if newCode != confirmCode {
            error = "Пароли не совпадают"; return
        }
        guard onSave(newCode) else {
            error = "Не удалось сохранить код в защищённом хранилище. Повторите попытку."
            return
        }
        dismiss()
    }
}
