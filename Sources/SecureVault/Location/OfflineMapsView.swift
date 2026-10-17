import SwiftUI

struct OfflineMapsView: View {
    @ObservedObject private var manager = OfflineMapManager.shared
    @State private var selectedID = ""
    @State private var search = ""
    @State private var zoom = 12
    @State private var deleteID: String?
    @State private var showActivity = false
    private var selected: OfflineRegion? { manager.regions.first { $0.id == selectedID } }
    private var filtered: [OfflineRegion] { manager.regions.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.iso.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        List {
            Section("Ваш регион") {
                Text(manager.suggestion).accessibilityIdentifier("offline.suggestion")
                Button("Определить по GPS ещё раз") { manager.detectRegion() }
                if let region = selected { Text("Выбрано: \(region.name)").font(.headline) }
                Picker("Детализация", selection: $zoom) {
                    Text("Обзор региона").tag(10)
                    Text("Улицы").tag(12)
                    Text("Здания").tag(14)
                }
                if let region = selected {
                    let count = region.bounds.tileCount(maxZoom: zoom)
                    if count < 200_000 {
                        Text("Примерный объём: \(ByteCountFormatter.string(fromByteCount: Int64(count) * 10_000, countStyle: .file))–\(ByteCountFormatter.string(fromByteCount: Int64(count) * 30_000, countStyle: .file)). Фактический размер зависит от плотности объектов.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Button("Скачать: \(region.name)") { manager.download(region, zoom: zoom) }
                        .accessibilityIdentifier("offline.download")
                }
                Text("Скачиваются карта, подписи и отдельная база запретных мест. Дождитесь статуса «Карта и зоны готовы». Большой регион лучше загружать через Wi-Fi, оставив приложение открытым.")
                    .font(.caption).foregroundColor(.secondary)
            }
            if !manager.rows.isEmpty {
                Section("Загруженные регионы") {
                    ForEach(manager.rows) { row in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(row.name).font(.headline)
                            Text(row.status).font(.caption).foregroundColor(row.ready ? .green : .secondary)
                            ProgressView(value: row.fraction)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(row.bytes), countStyle: .file)).font(.caption)
                            if manager.downloadingPlacesID == row.id,
                               let progress = manager.placesProgress,
                               progress.regionID == row.id {
                                VStack(alignment: .leading, spacing: 3) {
                                    ProgressView(value: progress.fraction)
                                    if let bytesLabel = progress.bytesLabel {
                                        Text("PBF: \(bytesLabel)")
                                            .font(.caption2).foregroundColor(.secondary)
                                    }
                                    Text(progress.phase.isEmpty ? "Загружаем объекты запретных зон…" : progress.phase)
                                        .font(.caption).foregroundColor(.secondary)
                                    Text("Зоны: \(progress.completedTiles) из \(progress.totalTiles) ячеек · найдено \(progress.placesCount) объектов" +
                                         (progress.failedTiles > 0 ? " · ошибок: \(progress.failedTiles)" : ""))
                                        .font(.caption)
                                        .foregroundColor(progress.failedTiles > 0 ? .orange : .secondary)
                                    if !progress.serverLabel.isEmpty {
                                        Text("\(progress.currentTileLabel) · \(progress.serverLabel)")
                                            .font(.caption2).foregroundColor(.secondary)
                                    }
                                    Button("Что происходит") { showActivity = true }
                                        .font(.caption).buttonStyle(.borderless)
                                }
                            }
                            HStack {
                                Button("Продолжить / обновить зоны") { manager.resume(row.id) }.buttonStyle(.borderless)
                                Spacer()
                                Button("Удалить", role: .destructive) { deleteID = row.id }.buttonStyle(.borderless)
                            }.font(.caption)
                        }.padding(.vertical, 4)
                    }
                    Button("Приостановить загрузки") { manager.pauseAll() }
                }
            }
            Section("Выбрать другой регион России") {
                TextField("Найти область, край или республику", text: $search).accessibilityIdentifier("offline.regionSearch")
                ForEach(filtered) { region in
                    Button {
                        selectedID = region.id
                    } label: {
                        HStack { Text(region.name).foregroundColor(.primary); Spacer(); if selectedID == region.id { Image(systemName: "checkmark") } }
                    }.accessibilityIdentifier("offline.region." + region.id)
                }
            }
            Section {
                Text("Без интернета карта работает в скачанном регионе и до выбранной детализации. Вне него подробности могут быть недоступны. GPS продолжает работать без интернета, но при глушении или погрешности от 15 м контроль заблокирует съёмку.")
                Text("База запретных мест действует 30 дней; затем её нужно обновить. Границы и объекты OpenStreetMap могут быть неполными. Незавершённая или устаревшая база не разрешает съёмку без проверки.")
                Link("© OpenStreetMap contributors · VersaTiles", destination: URL(string: "https://versatiles.org/")!)
            }.font(.footnote).foregroundColor(.secondary)
        }
        .navigationTitle("Офлайн-карты")
        .navigationBarTitleDisplayMode(.inline)
        .tint(.orange)
        .sheet(isPresented: $showActivity) {
            OfflinePlacesActivityView(manager: manager)
        }
        .onAppear { manager.open(); if selectedID.isEmpty { selectedID = manager.suggestedRegionID ?? "" } }
        .onChange(of: manager.suggestedRegionID) { if selectedID.isEmpty, let id = $0 { selectedID = id } }
        .alert("Офлайн-карты", isPresented: Binding(get: { manager.error != nil }, set: { if !$0 { manager.error = nil } })) {
            Button("Закрыть") { manager.error = nil }
        } message: { Text(manager.error ?? "") }
        .confirmationDialog("Удалить карту и базу зон этого региона?", isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } }), titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { if let id = deleteID { manager.remove(id) }; deleteID = nil }
            Button("Отмена", role: .cancel) { deleteID = nil }
        }
    }
}

private struct OfflinePlacesActivityView: View {
    @ObservedObject var manager: OfflineMapManager
    @Environment(\.dismiss) private var dismiss
    @State private var markerPulse = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let progress = manager.placesProgress {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Состояние загрузки").font(.headline)
                                Text("\(progress.completedTiles) / \(progress.totalTiles) ячеек · \(progress.placesCount) объектов")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                                    ForEach(0..<max(progress.totalTiles, 1), id: \.self) { index in
                                        let completed = index < progress.completedTiles
                                        let current = index == progress.completedTiles
                                        Circle()
                                            .fill(completed ? Color.green : (current ? Color.orange : Color.white.opacity(0.16)))
                                            .frame(height: 16)
                                            .scaleEffect(current && markerPulse ? 1.35 : 1)
                                            .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.5))
                                    }
                                }
                                if progress.failedTiles > 0 {
                                    Text("Ошибок ячеек: \(progress.failedTiles)")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                            .padding()
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                        }

                        Text("Журнал").font(.headline)
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(manager.placesActivity.enumerated()), id: \.offset) { index, message in
                                Text(message)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(message.contains("Ошибка") || message.contains("пропущена") ? .orange : .secondary)
                                    .id(index)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                }
                .onChange(of: manager.placesActivity.count) { _ in
                    if let last = manager.placesActivity.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .navigationTitle("Загрузка зон")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Готово") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.orange)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                markerPulse = true
            }
        }
    }
}

