import SwiftUI

struct GalleryView: View {
    @Environment(\.dismiss) var dismiss
    @State private var groupedPhotos: [PhotoEventGroup] = []
    @State private var photoTitles: [URL: String] = [:]
    @State private var eventKeys: [URL: String] = [:]
    @State private var photoDates: [URL: Date] = [:]
    @State private var reloadID = UUID()
    @State private var showSettings = false
    @State private var sharingItems: [Any] = []
    @State private var showShareSheet = false
    @State private var sharingText = ""
    @State private var eventPath: [String] = []
    @State private var isExporting = false
    @State private var isLoading = true
    @State private var isSelecting = false
    @State private var selectedURLs: Set<URL> = []
    @State private var showDeleteConfirm = false
    @State private var currentFolder: String?
    @State private var folders: [(String, Int)] = []
    @State private var operationError: String?
    @ObservedObject private var settings = SettingsStore.shared
    private let accessGeneration = VaultGate.shared.generation
    init() {}
    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
    private var days: [GalleryDayGroup] { GalleryGrouping.days(groupedPhotos) }
    private var totalCount: Int { groupedPhotos.reduce(0) { $0 + $1.urls.count } }
    private var selectedEventCount: Int {
        groupedPhotos.filter { group in group.urls.contains { selectedURLs.contains($0) } }.count
    }

    var body: some View {
        NavigationStack(path: $eventPath) {
            Group {
                if currentFolder == nil { folderList }
                else { eventList }
            }
            .background(Color.black)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                EventGalleryView(eventID: id, groups: groupedPhotos, photoTitles: photoTitles,
                    isExporting: isExporting, onShare: { shareDay(day: $0.title, urls: $0.urls) }, onDelete: delete)
            }
            .toolbar { galleryToolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isSelecting { selectionBar }
            }
        }
        .preferredColorScheme(.dark).tint(.orange)
        .onAppear { reload() }
        .onDisappear { reloadID = UUID() }
        .sheet(isPresented: $showSettings, onDismiss: { reload() }) { SettingsView() }
        .sheet(isPresented: $showShareSheet, onDismiss: {
            sharingItems = []; sharingText = ""
            PhotoExporter.cleanupTemporaryExports()
        }) {
            if sharingText.isEmpty { ShareSheet(items: sharingItems) }
            else { CoordinateSharePreview(items: sharingItems, text: sharingText) }
        }
        .alert("Удалить \(GalleryPresentation.eventCount(selectedEventCount))?", isPresented: $showDeleteConfirm) {
            Button("Удалить", role: .destructive) { deleteSelected() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Будут удалены \(selectedURLs.count) фото. Это действие нельзя отменить.")
        }
        .alert("Ошибка", isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
            Button("Закрыть") { operationError = nil }
        } message: { Text(operationError ?? "") }
    }

    private var folderList: some View {
        List {
            Section {
                ForEach(folders, id: \.0) { folder, count in
                    Button {
                        currentFolder = folder; groupedPhotos = []; reload()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "folder.fill").font(.title3).foregroundColor(.orange)
                                .frame(width: 44, height: 44)
                                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(folder).font(.body.weight(.medium)).foregroundStyle(.white)
                                Text("\(count) фото").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }.padding(.vertical, 3)
                    }
                    .accessibilityLabel("\(folder), \(count) фото")
                }
            } header: {
                Text("Папки").font(.largeTitle.weight(.bold)).foregroundStyle(.white).textCase(nil)
                    .padding(.bottom, 12)
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden)
    }

    private var eventList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(currentFolder ?? "").font(.largeTitle.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("gallery.folderTitle")
                    Text(GalleryPresentation.summary(events: groupedPhotos.count, photos: totalCount))
                        .font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("gallery.summary")
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 28)
                if groupedPhotos.isEmpty {
                    emptyFolder
                } else {
                    ForEach(days) { section in
                        Section {
                            eventGrid(section)
                        } header: {
                            dayHeader(section)
                        }
                    }
                }
            }
            .padding(.bottom, 20)
        }
    }

    private var emptyFolder: some View {
        VStack(spacing: 12) {
            if isLoading {
                ProgressView("Загрузка событий…").tint(.orange)
            } else {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 38, weight: .light)).foregroundStyle(.secondary)
                Text("Здесь появятся события").font(.headline)
                Text("Снимки одного события будут собраны под общей обложкой.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 32).padding(.vertical, 70)
    }

    private func eventGrid(_ section: GalleryDayGroup) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(section.events) { group in
                if let url = group.urls.first {
                    Button {
                        if isSelecting { toggleSelection(url) }
                        else { eventPath.append(group.id) }
                    } label: {
                        GalleryEventCard(url: url, title: group.title, date: group.date,
                            photoCount: group.urls.count, isSelecting: isSelecting, isSelected: selectedURLs.contains(url))
                    }
                    .buttonStyle(GalleryCardButtonStyle())
                    .accessibilityLabel("\(group.title), \(group.urls.count) фото, \(GalleryPresentation.time(group.date))")
                    .accessibilityValue(isSelecting ? (selectedURLs.contains(url) ? "Выбрано" : "Не выбрано") : "")
                    .accessibilityIdentifier("gallery.event." + group.id)
                    .contextMenu {
                        if !isSelecting {
                            Button { isSelecting = true; toggleSelection(url) } label: {
                                Label("Выбрать событие", systemImage: "checkmark.circle")
                            }
                            Button { shareDay(day: group.title, urls: group.urls) } label: {
                                Label("Выгрузить событие", systemImage: "square.and.arrow.up")
                            }.disabled(isExporting)
                            Button(role: .destructive) {
                                selectedURLs = Set(group.urls); isSelecting = true; showDeleteConfirm = true
                            } label: { Label("Удалить событие", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 22)
    }

    private func dayHeader(_ section: GalleryDayGroup) -> some View {
        let relative = Calendar.current.isDateInToday(section.date) || Calendar.current.isDateInYesterday(section.date)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(GalleryPresentation.date(section.date, relative: true)).font(.title3.weight(.semibold))
                Text(relative
                    ? "\(GalleryPresentation.date(section.date)) · \(GalleryPresentation.eventCount(section.events.count))"
                    : GalleryPresentation.summary(events: section.events.count, photos: section.urls.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !isSelecting {
                Button { shareDay(day: GalleryPresentation.date(section.date), urls: section.urls) } label: {
                    Group {
                        if isExporting { ProgressView().tint(.orange) }
                        else { Image(systemName: "square.and.arrow.up").font(.body.weight(.medium)) }
                    }
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.065), in: Circle())
                }
                .disabled(isExporting)
                .accessibilityLabel("Выгрузить события за \(GalleryPresentation.date(section.date))")
                .accessibilityIdentifier("gallery.shareDay." + section.id)
            }
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
        .background(.black.opacity(0.96))
    }

    @ToolbarContentBuilder
    private var galleryToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if isSelecting {
                Button("Отмена") { exitSelection() }
            } else {
                Button(currentFolder == nil ? "Закрыть" : "Папки") {
                    if currentFolder == nil { dismiss() }
                    else { currentFolder = nil; reload() }
                }
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(isSelecting ? "Готово" : "Выбрать") {
                if isSelecting { exitSelection() } else { isSelecting = true }
            }.disabled(currentFolder == nil).accessibilityIdentifier("gallery.select")
        }
        if !isSelecting {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Настройки").accessibilityIdentifier("gallery.settings")
            }
        }
    }

    private var selectionBar: some View {
        VStack(spacing: 12) {
            Text(selectedURLs.isEmpty ? "Выберите события" : "Выбрано: \(GalleryPresentation.summary(events: selectedEventCount, photos: selectedURLs.count))")
                .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("gallery.selectionSummary")
            HStack {
                Button { showDeleteConfirm = true } label: { selectionLabel("Удалить", icon: "trash") }
                    .foregroundStyle(selectedURLs.isEmpty ? Color.gray : .red)
                    .disabled(selectedURLs.isEmpty).accessibilityIdentifier("gallery.deleteSelected")
                Menu {
                    ForEach(["Без режима"] + settings.workModes.filter {
                        $0 != "Без режима" && $0.caseInsensitiveCompare("VaultPhotos") != .orderedSame
                    }, id: \.self) { folder in
                        Button(folder) {
                            do {
                                try FileStorageManager.shared.moveEvents(containing: Array(selectedURLs), to: folder)
                                exitSelection(); reload()
                            } catch { operationError = "Не удалось переместить событие: \(error.localizedDescription)" }
                        }
                    }
                } label: { selectionLabel("Переместить", icon: "folder.badge.arrow.forward") }
                    .disabled(selectedURLs.isEmpty).accessibilityIdentifier("gallery.moveSelected")
                Button { shareSelected() } label: {
                    if isExporting { ProgressView().frame(maxWidth: .infinity) }
                    else { selectionLabel("Выгрузить", icon: "square.and.arrow.up") }
                }
                .disabled(selectedURLs.isEmpty || isExporting).accessibilityIdentifier("gallery.shareSelected")
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
        .background(.ultraThinMaterial)
    }

    private func selectionLabel(_ title: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title3)
            Text(title).font(.caption)
        }.frame(maxWidth: .infinity, minHeight: 44)
    }

    private func toggleSelection(_ url: URL) {
        let key = eventKeys[url] ?? url.path
        let eventURLs = groupedPhotos.flatMap { $0.urls }.filter { eventKeys[$0] == key }
        if selectedURLs.contains(url) {
            selectedURLs.subtract(eventURLs)
        } else {
            selectedURLs.formUnion(eventURLs)
        }
    }

    private func exitSelection() {
        isSelecting = false
        selectedURLs.removeAll()
    }

    private func deleteSelected() {
        let failures = selectedURLs.filter { !FileStorageManager.shared.delete(url: $0) }
        if !failures.isEmpty { operationError = "Не удалось удалить \(failures.count) файлов" }
        exitSelection()
        reload()
    }

    private func shareSelected() {
        let urls = selectedURLs.sorted { (photoDates[$0] ?? .distantPast) < (photoDates[$1] ?? .distantPast) }
        shareDay(day: "Выбранные фото", urls: urls)
    }

    private func shareDay(day: String, urls: [URL]) {
        guard !urls.isEmpty, !isExporting else { return }
        let notes = settings.notesOnExport
        let numbering = settings.numberingMode
        let metadata = settings.archiveMetadata
        let coordinates = settings.coordinatesOnShare
        let ordered = urls.sorted {
            let lhs = photoDates[$0] ?? .distantPast, rhs = photoDates[$1] ?? .distantPast
            return lhs == rhs ? $0.path < $1.path : lhs < rhs
        }

        guard SettingsStore.shared.exportAsZip else {
            isExporting = true
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { () -> ([URL], String) in
                    let files = try PhotoExporter.copies(of: ordered, includeNotes: notes, generation: accessGeneration, numberingMode: numbering)
                    let text = try VaultGate.shared.withAccess(generation: accessGeneration) {
                        coordinates ? ExportMetadata.coordinateMessage(ordered.map {
                            ExportPhotoRecord(filename: $0.lastPathComponent, meta: FileStorageManager.shared.loadMeta(for: $0), folder: "")
                        }) : ""
                    }
                    return (files, text)
                }
                DispatchQueue.main.async {
                    isExporting = false
                    guard VaultGate.shared.generation == accessGeneration else { return }
                    switch result {
                    case .success(let payload):
                        sharingText = payload.1
                        sharingItems = ExportMetadata.messageParts(payload.1).map { $0 as Any } + payload.0.map { $0 as Any }
                        showShareSheet = true
                    case .failure(let error): operationError = "Экспорт не выполнен: \(error.localizedDescription)"
                    }
                }
            }
            return
        }

        isExporting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let zipURL = ZipExporter.exportDay(label: day, urls: ordered, includeNotes: notes,
                generation: accessGeneration, numberingMode: numbering, metadata: metadata)
            DispatchQueue.main.async {
                isExporting = false
                guard VaultGate.shared.generation == accessGeneration else { return }
                sharingText = ""
                if let zipURL = zipURL {
                    sharingItems = [zipURL]
                    showShareSheet = true
                } else { operationError = "Не удалось создать архив. Проверьте свободное место." }
            }
        }
    }

    private func reload() {
        let requestID = UUID()
        reloadID = requestID
        isLoading = true
        let folder = currentFolder
        let modes = settings.workModes.filter { $0.caseInsensitiveCompare("VaultPhotos") != .orderedSame }
        let numberingMode = settings.numberingMode
        let generation = accessGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let storage = FileStorageManager.shared
            let records = storage.loadAllWithMeta().map { url, meta in
                GalleryRecord(url: url, meta: meta,
                    date: meta?.date ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast,
                    folder: storage.folder(for: url), eventKey: meta?.eventID?.uuidString ?? url.path)
            }
            var counts: [String: Int] = [:]
            var titles: [URL: String] = [:]
            var keys: [URL: String] = [:]
            var dates: [URL: Date] = [:]
            for record in records {
                counts[record.folder, default: 0] += 1
                titles[record.url] = storage.title(for: record.url, meta: record.meta, numberingMode: numberingMode)
                keys[record.url] = record.eventKey
                dates[record.url] = record.date
            }
            let names = Set(["Без режима"] + modes + Array(counts.keys))
            let folderRows = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { ($0, counts[$0] ?? 0) }
            let groups = GalleryGrouping.events(records.filter { $0.folder == folder })
            DispatchQueue.main.async {
                guard self.reloadID == requestID, VaultGate.shared.generation == generation else { return }
                self.folders = folderRows
                self.groupedPhotos = groups
                self.photoTitles = titles
                self.eventKeys = keys
                self.photoDates = dates
                self.isLoading = false
            }
        }
    }

    private func delete(url: URL) {
        if !FileStorageManager.shared.delete(url: url) { operationError = "Не удалось удалить фото" }
        reload()
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

extension URL: Identifiable { public var id: String { absoluteString } }
