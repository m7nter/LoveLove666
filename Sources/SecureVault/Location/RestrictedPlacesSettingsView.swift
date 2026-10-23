import SwiftUI

struct RestrictedPlacesSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var offline = OfflineMapManager.shared
    @ObservedObject private var monitor = RestrictedPlacesMonitor.shared
    @State private var offerDownload = false
    @State private var showOffline = false
    var body: some View {
        Form {
            Section {
                Toggle("Контроль запретных мест", isOn: $store.restrictedPlaces.enabled)
                    .accessibilityIdentifier("settings.restrictedPlaces.enabled")
            } footer: {
                Text("Во время работы камеры проверяем ближайшие территории по OpenStreetMap. В запретной зоне съёмка блокируется, сверху отображается причина и расстояние до границы.")
            }
            Section("Режим проверки") {
                Picker("Источник данных", selection: $store.restrictedPlaces.checkMode) {
                    ForEach(RestrictedPlacesCheckMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text(store.restrictedPlaces.checkMode.description)
                    .font(.caption).foregroundColor(.secondary)
                if store.restrictedPlaces.checkMode == .online {
                    Text("При отсутствии ответа OSM съёмка блокируется до успешной проверки.")
                        .font(.caption).foregroundColor(.orange)
                }
            }
            Section("Состояние OSM") {
                Label(
                    monitor.decision.blocked ? "Съёмка сейчас заблокирована" : "Съёмка разрешена текущей проверкой",
                    systemImage: monitor.decision.blocked ? "lock.fill" : "checkmark.shield.fill")
                    .font(.subheadline)
                    .foregroundColor(monitor.decision.blocked ? .orange : .green)
                Text(monitor.lastCheckSummary)
                    .font(.caption).foregroundColor(.secondary)
                Button("Проверить сейчас") { monitor.retryNow() }
                    .disabled(!store.restrictedPlaces.enabled)
                Text("Если камера закрыта, запрос начнётся при её открытии. Пока онлайн‑проверка не завершилась, съёмка остаётся заблокирована.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Точность координат") {
                Picker("Блокировать при погрешности от", selection: $store.restrictedPlaces.maximumAccuracy) {
                    ForEach([5, 10, 15, 20, 30, 50], id: \.self) { Text("\($0) м").tag(Double($0)) }
                }
                Text("По умолчанию ±15 м и хуже — съёмка запрещена. Нет свежего GPS или данных о территории — съёмка также запрещена. У границы учитывается запас на погрешность GPS.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Без интернета") {
                NavigationLink("Офлайн-карты и запретные места", destination: OfflineMapsView())
                    .accessibilityIdentifier("settings.offlineMaps")
                Text("Скачайте регион заранее: карта и база зон сохраняются отдельно. В скачанной области контроль работает без интернета при хорошем GPS.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Типы мест и расстояния") {
                ForEach(RestrictedPlaceKind.allCases) { kind in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(kind.title, isOn: Binding(
                            get: { store.restrictedPlaces.includes(kind) },
                            set: { enabled in
                                if enabled { store.restrictedPlaces.disabledKinds.remove(kind) }
                                else { store.restrictedPlaces.disabledKinds.insert(kind) }
                            }))
                        if store.restrictedPlaces.includes(kind) {
                            Stepper(value: Binding(
                                get: { Int(store.restrictedPlaces.radius(for: kind)) },
                                set: { store.restrictedPlaces.radii[kind.rawValue] = Double($0) }), in: 5...1000, step: 5) {
                                Text("До границы: \(Int(store.restrictedPlaces.radius(for: kind))) м").font(.subheadline).foregroundColor(.secondary)
                            }
                            .accessibilityIdentifier("settings.restrictedPlaces.radius." + kind.rawValue)
                        }
                    }.padding(.vertical, 3)
                }
                Button("Вернуть расстояния 65 / 100 м") { store.restrictedPlaces.radii = [:] }
            }
            Section {
                Text("Граница — контур территории на карте (например, забор детского сада). Если отмечено только здание или точка, расстояние считается от них. Внутри контура расстояние равно 0 м.")
                Text("Карта может не содержать учреждение или его забор. Контроль не гарантирует отсутствие ненанесённых объектов.")
                Text("Для проверки область текущих координат передаётся сервису Overpass. Фотографии, заметки и коды не передаются. При сворачивании приложения проверка приостанавливается; после возврата данные проверяются заново.")
                Link("Данные © OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
            }.font(.footnote).foregroundColor(.secondary)
        }
        .tint(.orange)
        .navigationTitle("Запретные места")
        .navigationBarTitleDisplayMode(.inline)
        .background(NavigationLink(destination: OfflineMapsView(), isActive: $showOffline) { EmptyView() }.hidden())
        .onChange(of: store.restrictedPlaces.enabled) { enabled in
            if enabled && store.restrictedPlaces.checkMode != .online {
                offline.open(); offerDownload = true
            }
        }
        .alert("Скачать регион для работы без интернета?", isPresented: $offerDownload) {
            Button("Выбрать и скачать") { showOffline = true }
            Button("Позже", role: .cancel) {}
        } message: { Text(offline.suggestion + " Регион можно изменить в списке.") }
    }
}

