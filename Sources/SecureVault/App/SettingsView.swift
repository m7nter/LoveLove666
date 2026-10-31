import SwiftUI
import CoreLocation

struct SettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var inactivity = InactivityTimerManager.shared
    @ObservedObject private var locationManager = LocationManager.shared
    @Environment(\.dismiss) var dismiss
    @Environment(\.openURL) private var openURL
    @State private var path: [SettingsDestination] = []
    @State private var search = ""
    @State private var showPicker = false
    @State private var showChangeMain = false
    @State private var showChangeVault = false
    @State private var showChangeKamikaze = false
    @State private var showActionButtonWarning = false
    @State private var showGuide = false
    @State private var pendingActionMode: ActionButtonMode = .off
    @State private var newMode = ""
    @State private var showInactivityConfirmation = false
    @State private var pendingInactivityHours = 0
    @State private var showBruteForceConfirmation = false
    @State private var pendingBruteForceLimit = 0

    var body: some View {
        NavigationStack(path: $path) {
            homeContent
                .navigationTitle("Настройки")
                .navigationBarTitleDisplayMode(.large)
                .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Поиск по настройкам")
                .toolbar { doneButton }
                .navigationDestination(for: SettingsDestination.self) { destination in
                    destinationContent(destination).toolbar { doneButton }
                }
        }
        .preferredColorScheme(.dark).tint(.orange)
        .sheet(isPresented: $showPicker) {
            ImagePicker { img in store.avatarImage = img }
        }
        .sheet(isPresented: $showGuide) {
            WelcomeGuideView()
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
        .sheet(isPresented: $showInactivityConfirmation) {
            InactivityConfirmationView(hours: pendingInactivityHours) {
                _ = inactivity.activate(hours: pendingInactivityHours)
            }
        }
        .sheet(isPresented: $showBruteForceConfirmation) {
            BruteForceConfirmationView(attempts: pendingBruteForceLimit) {
                store.failedPasswordWipeLimit = pendingBruteForceLimit
                store.resetPasswordFailureState()
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


    private var homeContent: some View {
        List {
            if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section {
                    Button { showGuide = true } label: {
                        settingsRow(title: "Руководство по использованию", detail: "Что умеет приложение и как им пользоваться", icon: "book.closed.fill")
                    }.accessibilityIdentifier("settings.guide")
                }
                Section("Разделы") {
                    ForEach(SettingsCategory.allCases) { category in
                        NavigationLink(value: SettingsDestination.category(category, focus: nil)) {
                            settingsRow(title: category.title, detail: category.detail, icon: category.icon)
                        }.accessibilityIdentifier("settings.category." + category.rawValue)
                    }
                }
            } else {
                searchResults
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(Color.black)
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = SettingsCatalog.search(search)
        if results.isEmpty {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Настройки не найдены").font(.headline).accessibilityIdentifier("settings.search.empty")
                    Text("Попробуйте: GPS, пароль, координаты").font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 28)
            }
        } else {
            Section("Найдено: \(results.count)") {
                ForEach(results) { entry in
                    if let destination = entry.destination {
                        NavigationLink(value: destination) { searchRow(entry) }
                            .accessibilityIdentifier("settings.search." + entry.id.rawValue)
                    } else {
                        Button { showGuide = true } label: { searchRow(entry) }
                            .accessibilityIdentifier("settings.search." + entry.id.rawValue)
                    }
                }
            }
        }
    }

    private func settingsRow(title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 20, weight: .medium)).foregroundStyle(.orange)
                .frame(width: 44, height: 44)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 5)
    }

    private func searchRow(_ entry: SettingsSearchEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.title).font(.body).foregroundStyle(.white)
            Text(entry.category?.title ?? "Помощь").font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }

    @ToolbarContentBuilder
    private var doneButton: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button("Готово") { dismiss() }.accessibilityIdentifier("settings.done")
        }
    }

    @ViewBuilder
    private func destinationContent(_ destination: SettingsDestination) -> some View {
        switch destination {
        case .category(let category, let focus): categoryPage(category, focus: focus)
        case .restrictedPlaces: RestrictedPlacesSettingsView()
        case .offlineMaps: OfflineMapsView()
        }
    }

    private func categoryPage(_ category: SettingsCategory, focus: SettingsItem?) -> some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    Text(category.detail).font(.subheadline).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
                categorySections(category)
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(Color.black)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(category.title).navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard let focus else { return }
                DispatchQueue.main.async { proxy.scrollTo(focus, anchor: .top) }
            }
        }
    }

    @ViewBuilder
    private func categorySections(_ category: SettingsCategory) -> some View {
        switch category {
        case .location:
            restrictedPlacesSection
            offlineMapsSection
            continuousGPSSection
            gpsAccuracySection
            mapPinsSection
        case .camera:
            volumeCaptureSection
            crosshairSection
            blackScreenSection
        case .events:
            eventPhotosSection
            eventDistanceSection
            foldersSection
            numberingSection
        case .appearance:
            avatarSection
            annotationSection
        case .export:
            exportFormatSection
            exportCoordinatesSection
            archiveMetadataSection
            exportNoteSection
        case .security:
            mainPINSection
            lockingSection
            vaultPINSection
            emergencyPINSection
            bruteForceSection
            inactivitySection
        case .actionButton:
            actionButtonSection
        }
    }

    private var numberingSection: some View {
        Section("Нумерация фото") {
            Picker("Номера", selection: $store.numberingMode) {
                Text("Выключена").tag("off")
                Text("За день").tag("daily")
                Text("Общая").tag("total")
                Text("За день и общая").tag("both")
            }
            Text("Номера отображаются под снимками и в именах экспортируемых файлов. Удаление фото не сбрасывает счётчик.")
                .font(.caption).foregroundColor(.secondary)
        }.id(SettingsItem.numbering)
    }

    private var foldersSection: some View {
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
        }.id(SettingsItem.folders)
    }

    private var eventPhotosSection: some View {
        Section("События") {
            Stepper("Фото на событие: \(store.photosPerEvent)", value: $store.photosPerEvent, in: 1...20)
                .accessibilityIdentifier("settings.photosPerEvent")
            Text("Каждый кадр снимается отдельно. Серия объединяется в одно событие и одну папку. Настройка применяется к следующему событию; незавершённую серию можно закончить вручную.")
                .font(.caption).foregroundColor(.secondary)
        }.id(SettingsItem.eventPhotos)
    }

    private var blackScreenSection: some View {
        Section("Чёрный экран") {
            Toggle("Два касания тремя пальцами", isOn: $store.blackScreenEnabled)
            Text("Жест в камере скрывает экран; повторный жест возвращает его. Геолокация продолжает обновляться, пока приложение активно. Это не блокировка iPhone; GPS зависит от условий приёма, режим расходует батарею.")
                .font(.caption).foregroundColor(.secondary)
        }.id(SettingsItem.blackScreen)
    }

    private var annotationSection: some View {
        Section("Пометки на фото") {
            Picker("Цвет стрелок, овалов и текста", selection: $store.annotationColor) {
                Text("Красный").tag("red")
                Text("Жёлтый").tag("yellow")
                Text("Белый").tag("white")
                Text("Чёрный").tag("black")
            }
        }.id(SettingsItem.annotation)
    }

    private var avatarSection: some View {
        Section("Фото в углу снимка") {
            HStack(spacing: 16) {
                if let img = store.avatarImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("settings.footerAvatar")
                        .accessibilityLabel("Фото на снимках")
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
            if let error = store.avatarError {
                Text(error).font(.caption).foregroundColor(.red)
            }
            Text("Эта картинка добавляется в правом нижнем углу готового снимка.").font(.caption).foregroundStyle(.secondary)
        }.id(SettingsItem.avatar)
    }

    private var crosshairSection: some View {
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
        }.id(SettingsItem.crosshair)
    }

    private var restrictedPlacesSection: some View {
        Section("Контроль территорий OSM") {
            NavigationLink(value: SettingsDestination.restrictedPlaces) {
                HStack {
                    Text("Контроль территорий")
                    Spacer()
                    Text(store.restrictedPlaces.enabled ? "Включён" : "Выключен").foregroundColor(.secondary)
                }
            }.accessibilityIdentifier("settings.restrictedPlaces")
            Text("Онлайн-, офлайн- и автоматическая проверка OSM. Здесь выбираются типы мест, расстояния до границ и условия блокировки съёмки.")
                .font(.caption).foregroundColor(.secondary)
        }.id(SettingsItem.restrictedPlaces)
    }

    private var continuousGPSSection: some View {
        Section("GPS без ожидания") {
            Toggle("Поддерживать GPS активным", isOn: $store.continuousGPSEnabled)
                .tint(.orange).accessibilityIdentifier("settings.continuousGPS")
            Text("Для более быстрого получения точных координат при открытии камеры. GPS продолжает обновляться в калькуляторе и, с разрешением iOS «Всегда», в фоне.")
                .font(.caption).foregroundColor(.secondary)
            Text("Режим не открывает хранилище и не отключает PIN, шифрование или автоблокировку. История перемещений не записывается.")
                .font(.caption).foregroundColor(.secondary)
            if store.continuousGPSEnabled {
                if locationManager.authorizationStatus == .authorizedAlways {
                    Label("Геопозиция в фоне разрешена", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundColor(.green)
                } else {
                    Button("Разрешить геопозицию «Всегда»") {
                        locationManager.requestContinuousAuthorization()
                    }.foregroundColor(.orange)
                    Text("В настройках iOS выберите «Всегда» и включите «Точная геопозиция». При разрешении «При использовании» GPS поддерживается только в открытом приложении.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Button("Открыть настройки геопозиции iOS") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }.foregroundColor(.orange)
                Text("Постоянный GPS расходует больше заряда; iOS может показывать индикатор геолокации. После принудительного закрытия приложения обновления прекращаются. Свежесть и точность координат проверяются перед съёмкой как обычно.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }.id(SettingsItem.continuousGPS)
    }

    private var gpsAccuracySection: some View {
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
        }.id(SettingsItem.gpsAccuracy)
    }

    private var eventDistanceSection: some View {
        Section("Дистанция между событиями") {
            Toggle("Показывать дистанцию между событиями", isOn: $store.distanceTrackingEnabled)
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
                Text("Расстояние проверяется при начале следующего события и считается от первого кадра предыдущего. Внутри одного события можно снимать на месте; при недостаточной дистанции новое событие блокируется.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }.id(SettingsItem.eventDistance)
    }

    private var actionButtonSection: some View {
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
        }.id(SettingsItem.actionButton)
    }

    private var volumeCaptureSection: some View {
        Section("Кнопки камеры") {
            Toggle("Снимать кнопками громкости", isOn: $store.volumeButtonCaptureEnabled)
                .accessibilityIdentifier("settings.volumeCapture")
                .tint(.orange)
        }.id(SettingsItem.volumeCapture)
    }

    private var archiveMetadataSection: some View {
        Section("Метаданные ZIP-архива") {
            Picker("Метаданные", selection: Binding<String>(
                get: { store.archiveMetadata == .coordinates ? "coordinates" : store.archiveMetadata == .all ? "all" : store.archiveMetadata.isEmpty ? "none" : "custom" },
                set: {
                    switch $0 {
                    case "coordinates": store.archiveMetadata = .coordinates
                    case "all": store.archiveMetadata = .all
                    case "none": store.archiveMetadata = []
                    default: break
                    }
                })) {
                Text("Только координаты").tag("coordinates")
                Text("Все метаданные").tag("all")
                Text("Без метаданных").tag("none")
                Text("Выбрать поля").tag("custom")
            }.accessibilityIdentifier("settings.archiveMetadata")
            ForEach(ArchiveMetadataOptions.fields, id: \.0) { name, field in
                Toggle(name, isOn: Binding(
                    get: { store.archiveMetadata.contains(field) },
                    set: { enabled in
                        if enabled { store.archiveMetadata.insert(field) }
                        else { store.archiveMetadata.remove(field) }
                    }))
            }
            Text("Поля добавляются в metadata.txt. В режиме «Только координаты» — только список координат; имена фото становятся photo-0001.jpg и не раскрывают дату, папку или событие. Надписи, уже нанесённые на сам снимок, остаются видимыми.")
                .font(.caption).foregroundColor(.secondary)
        }.id(SettingsItem.archiveMetadata)
    }

    private var inactivitySection: some View {
        Section("Автоматическое уничтожение") {
            Toggle("Включить Dead Man's Switch", isOn: inactivityEnabledBinding)
                .accessibilityIdentifier("settings.inactivityEnabled")
                .tint(.red)
            if inactivity.isEnabled {
                Picker("При неактивности", selection: inactivityHoursBinding) {
                    Text("24 часа").tag(24)
                    Text("48 часов").tag(48)
                    Text("72 часа").tag(72)
                    Text("7 дней").tag(168)
                }
                .accessibilityIdentifier("settings.inactivityTimer")
            }
            Text("Если приложение не будет запущено и разблокировано до истечения интервала, хранилище будет полностью уничтожено. Откат системного времени также считается попыткой обхода и может немедленно стереть данные.")
                .font(.caption)
                .foregroundColor(.red)
            if let error = inactivity.lastError {
                Text(error).font(.caption).foregroundColor(.red)
            }
        }.id(SettingsItem.inactivity)
    }

    private var lockingSection: some View {
        Section("Автоблокировка") {
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
        }.id(SettingsItem.locking)
    }

    private var mainPINSection: some View {
        Section("Основной пароль") {
            Button("Изменить основной пароль") { showChangeMain = true }
                .foregroundColor(.orange)
            if store.mainCode == "2026" {
                Text("Используется стандартный код 2026. Смените его перед работой с чувствительными материалами.")
                    .font(.caption).foregroundColor(.red)
            }

            Text("Основной код открывает главное меню через калькулятор.").font(.caption).foregroundStyle(.secondary)
        }.id(SettingsItem.mainPIN)
    }

    private var vaultPINSection: some View {
        Section("Дополнительный пароль") {
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

            Text("Дополнительный запрос кода при открытии папок, карты меток и дневника.").font(.caption).foregroundStyle(.secondary)
        }.id(SettingsItem.vaultPIN)
    }

    private var emergencyPINSection: some View {
        Section("Экстренное удаление фото") {
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
        }.id(SettingsItem.emergencyPIN)
    }

    private var bruteForceSection: some View {
        Section("Защита от перебора пароля") {
            Picker("Стирание после неверных паролей", selection: bruteForceLimitBinding) {
                Text("Выключено").tag(0)
                Text("3 попытки").tag(3)
                Text("5 попыток").tag(5)
                Text("10 попыток").tag(10)
                Text("20 попыток").tag(20)
            }
            .accessibilityIdentifier("settings.failedPasswordWipeLimit")
            Text("Функция считает неправильные попытки ввода основного пароля. После выбранного лимита данные будут уничтожены, а доступ к хранилищу закроется без возможности создать новый код в приложении.")
                .font(.caption).foregroundColor(.red)
        }.id(SettingsItem.bruteForce)
    }

    private var exportNoteSection: some View {
        Section("Заметка на выгружаемом фото") {
            Toggle("Впечатывать заметку на фото", isOn: $store.notesOnExport)
            Text("Заметка накладывается внизу снимка без изменения его размеров и пропорций. Оригинал в хранилище не меняется.")
                .font(.caption).foregroundColor(.secondary)
        }.id(SettingsItem.exportNote)
    }

    private var exportFormatSection: some View {
        Section("Способ выгрузки") {
            Picker("Способ выгрузки", selection: $store.exportAsZip) {
                Text("ZIP-архивом").tag(true)
                Text("Отдельными файлами").tag(false)
            }
            .pickerStyle(.segmented)
            Text("ZIP объединяет файлы в архив. Отдельные фотографии передаются через системное меню «Поделиться».").font(.caption).foregroundStyle(.secondary)
        }.id(SettingsItem.exportFormat)
    }

    private var exportCoordinatesSection: some View {
        Section("Координаты в сообщении") {
            Toggle("Координаты сообщением со снимками", isOn: $store.coordinatesOnShare)
                .accessibilityIdentifier("settings.coordinatesOnShare")
            Text("Добавляет дату выгрузки и пронумерованные координаты первого кадра каждого события — 6 знаков после запятой. Текст можно скопировать перед отправкой в Telegram или другое приложение.")
                .font(.caption).foregroundColor(.secondary)
        }.id(SettingsItem.exportCoordinates)
    }

    private var mapPinsSection: some View {
        Section("Метки фотографий на карте") {
            Toggle("Объединять близкие метки", isOn: $store.clusterMapPins)
                .tint(.orange)
            Text("Если фото сделаны рядом друг с другом, метки на карте будут объединяться в один кружок с числом снимков. При увеличении масштаба метки разделяются")
                .font(.caption)
                .foregroundColor(.secondary)
        }.id(SettingsItem.mapPins)
    }

    private var offlineMapsSection: some View {
        Section("Карты без интернета") {
            NavigationLink(value: SettingsDestination.offlineMaps) {
                Label("Офлайн-карты и зоны", systemImage: "arrow.down.circle")
            }.accessibilityIdentifier("settings.offlineMaps")
            Text("Загрузка региона, состояние карты и базы запретных мест. Офлайн-проверка быстрее онлайн-запроса.")
                .font(.caption).foregroundStyle(.secondary)
        }.id(SettingsItem.offlineMaps)
    }

    private func color(for name: String) -> Color {
        switch name {
        case "red": return .red
        case "green": return .green
        case "yellow": return .yellow
        default: return .white
        }
    }

    private var inactivityEnabledBinding: Binding<Bool> {
        Binding(
            get: { inactivity.isEnabled },
            set: { value in
                if value {
                    pendingInactivityHours = inactivity.limitHours > 0 ? inactivity.limitHours : 24
                    showInactivityConfirmation = true
                } else {
                    inactivity.disable()
                }
            })
    }

    private var inactivityHoursBinding: Binding<Int> {
        Binding(
            get: { inactivity.limitHours },
            set: { value in
                pendingInactivityHours = value
                showInactivityConfirmation = true
            })
    }

    private var bruteForceLimitBinding: Binding<Int> {
        Binding(
            get: { store.failedPasswordWipeLimit },
            set: { value in
                if value == 0 {
                    store.failedPasswordWipeLimit = 0
                    store.resetPasswordFailureState()
                } else {
                    pendingBruteForceLimit = value
                    showBruteForceConfirmation = true
                }
            })
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
