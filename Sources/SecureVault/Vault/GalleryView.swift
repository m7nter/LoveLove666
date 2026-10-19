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
    @State private var sequentialEventPlan: EventSharePlan?
    @State private var eventPath: [String] = []
    @State private var isExporting = false
    @State private var isSelecting = false
    @State private var selectedURLs: Set<URL> = []
    @State private var showDeleteConfirm = false
    @State private var currentFolder: String?
    @State private var folders: [(String, Int)] = []
    @State private var operationError: String?
    @ObservedObject private var settings = SettingsStore.shared
    private let accessGeneration = VaultGate.shared.generation
    init() {}
    private let columns = [GridItem(.adaptive(minimum: 145), spacing: 12)]
    private var days: [GalleryDayGroup] { GalleryGrouping.days(groupedPhotos) }
    private func dayTitle(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM yyyy"; return formatter.string(from: date)
    }

    private var totalCount: Int {
        groupedPhotos.reduce(0) { $0 + $1.urls.count }
    }

    var body: some View {
        NavigationStack(path: $eventPath) {
            ZStack(alignment: .bottom) {
                if currentFolder == nil {
                    List {
                        ForEach(folders, id: \.0) { folder, count in
                            Button {
                                currentFolder = folder; reload()
                            } label: {
                                HStack {
                                    Image(systemName: "folder.fill").foregroundColor(.orange)
                                    Text(folder)
                                    Spacer()
                                    Text("\(count) фото").foregroundColor(.secondary)
                                    Image(systemName: "chevron.right").foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(days) { section in
                            let day = dayTitle(section.date)
                            let urls = section.urls
                            Section {
                                LazyVGrid(columns: columns, spacing: 12) {
                                    ForEach(section.events) { group in
                                        if let url = group.urls.first {
                                        ThumbnailCell(
                                            url: url,
                                            title: group.title,
                                            photoCount: group.urls.count,
                                            isSelecting: isSelecting,
                                            isSelected: selectedURLs.contains(url)
                                        )
                                        .onTapGesture {
                                            if isSelecting {
                                                toggleSelection(url)
                                            } else {
                                                eventPath.append(group.id)
                                            }
                                        }
                                        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
                                        .accessibilityIdentifier("gallery.event." + group.id)
                                        }
                                    }
                                }
                                .padding(.horizontal, 12).padding(.bottom, 12)
                            } header: {
                                HStack {
                                    Text("\(day) · \(section.events.count) событий · \(urls.count) фото")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.white)
                                    Spacer()
                                    if !isSelecting {
                                        Button {
                                            shareDay(day: day, urls: urls)
                                        } label: {
                                            if isExporting {
                                                ProgressView()
                                                    .tint(.orange)
                                            } else {
                                                Image(systemName: "square.and.arrow.up")
                                                    .foregroundColor(.orange)
                                                    .font(.system(size: 16))
                                            }
                                        }
                                        .disabled(isExporting)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.black.opacity(0.85))
                            }
                        }
                    }
                    .padding(.bottom, isSelecting ? 70 : 0)
                }
                .background(Color.black)
                }

                if isSelecting {
                    HStack(spacing: 24) {
                        Button {
                            showDeleteConfirm = true
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "trash")
                                Text("Удалить")
                                    .font(.caption)
                            }
                        }
                        .foregroundColor(selectedURLs.isEmpty ? .gray : .red)
                        .disabled(selectedURLs.isEmpty)

                        Spacer()

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
                        } label: { Image(systemName: "folder.badge.arrow.forward") }
                        .disabled(selectedURLs.isEmpty)

                        Text("\(selectedURLs.count) выбрано")
                            .font(.subheadline)
                            .foregroundColor(.white)

                        Spacer()

                        Button {
                            shareSelected()
                        } label: {
                            if isExporting {
                                ProgressView().tint(.orange)
                            } else {
                                VStack(spacing: 4) {
                                    Image(systemName: "square.and.arrow.up")
                                    Text("Поделиться")
                                        .font(.caption)
                                }
                            }
                        }
                        .foregroundColor(selectedURLs.isEmpty ? .gray : .orange)
                        .disabled(selectedURLs.isEmpty || isExporting)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.95))
                }
            }
            .navigationTitle(currentFolder.map { "\($0) (\(totalCount))" } ?? "Хранилище папок")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                EventGalleryView(eventID: id, groups: groupedPhotos, photoTitles: photoTitles,
                    isExporting: isExporting, onShare: { shareDay(day: $0.title, urls: $0.urls) }, onDelete: delete)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if isSelecting {
                        Button("Отмена") { exitSelection() }
                            .foregroundColor(.orange)
                    } else {
                        Button(currentFolder == nil ? "Закрыть" : "Папки") {
                            if currentFolder == nil { dismiss() }
                            else { currentFolder = nil; reload() }
                        }
                            .foregroundColor(.orange)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            if isSelecting {
                                exitSelection()
                            } else {
                                isSelecting = true
                            }
                        } label: {
                            Text(isSelecting ? "Готово" : "Выбрать")
                                .foregroundColor(.orange)
                        }
                        .disabled(currentFolder == nil)
                        if !isSelecting {
                            Button {
                                showSettings = true
                            } label: {
                                Image(systemName: "gear")
                                    .foregroundColor(.orange)
                            }
                            .accessibilityIdentifier("gallery.settings")
                        }
                    }
                }
            }
        }
        .onAppear { reload() }
        .onDisappear { reloadID = UUID() }
        .sheet(isPresented: $showSettings, onDismiss: { reload() }) {
            SettingsView()
        }
        .sheet(isPresented: $showShareSheet, onDismiss: {
            sharingItems = []
            sharingText = ""
            PhotoExporter.cleanupTemporaryExports()
        }) {
            if sharingText.isEmpty { ShareSheet(items: sharingItems) }
            else { CoordinateSharePreview(items: sharingItems, text: sharingText) }
        }
        .sheet(item: $sequentialEventPlan, onDismiss: {
            PhotoExporter.cleanupTemporaryExports()
        }) { plan in
            SequentialEventShareView(plan: plan)
        }
        .alert(
            "Удалить \(selectedURLs.count) фото?",
            isPresented: $showDeleteConfirm
        ) {
            Button("Удалить", role: .destructive) { deleteSelected() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Это действие нельзя отменить.")
        }
        .alert("Ошибка", isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
            Button("Закрыть") { operationError = nil }
        } message: { Text(operationError ?? "") }
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

        if !settings.exportAsZip && coordinates {
            prepareSequentialEventShare(ordered: ordered, notes: notes, numbering: numbering)
            return
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
                        // Keep all event photos contiguous and provide them as
                        // image items so Telegram can form one album instead
                        // of treating each temporary file URL as a message.
                        sharingItems = PhotoExporter.shareItems(of: payload.0)
                            + ExportMetadata.messageParts(payload.1).map { $0 as Any }
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

    private func prepareSequentialEventShare(ordered: [URL], notes: Bool, numbering: String?) {
        let groups = eventGroups(containing: ordered)
        guard !groups.isEmpty else { return }
        isExporting = true
        let generation = accessGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> EventSharePlan in
                var payloads: [EventShareItem] = []
                for group in groups {
                    let files = try PhotoExporter.copies(of: group.urls, includeNotes: notes,
                                                         generation: generation, numberingMode: numbering)
                    let records = group.urls.map {
                        ExportPhotoRecord(filename: $0.lastPathComponent,
                                          meta: FileStorageManager.shared.loadMeta(for: $0), folder: "")
                    }
                    let caption = ExportMetadata.eventCoordinateCaption(records, title: group.title)
                    payloads.append(EventShareItem(id: group.id, title: group.title, files: files, caption: caption))
                }
                let records = ordered.map {
                    ExportPhotoRecord(filename: $0.lastPathComponent,
                                      meta: FileStorageManager.shared.loadMeta(for: $0), folder: "")
                }
                let final = groups.count > 1 ? ExportMetadata.coordinateMessage(records) : nil
                return EventSharePlan(events: payloads, finalMessage: final)
            }
            DispatchQueue.main.async {
                isExporting = false
                guard VaultGate.shared.generation == generation else { return }
                switch result {
                case .success(let plan): sequentialEventPlan = plan
                case .failure(let error):
                    PhotoExporter.cleanupTemporaryExports()
                    operationError = "Экспорт событий не выполнен: \(error.localizedDescription)"
                }
            }
        }
    }

    private func eventGroups(containing ordered: [URL]) -> [PhotoEventGroup] {
        let wanted = Set(ordered)
        let order = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1, $0) })
        return groupedPhotos.compactMap { group in
            let urls = group.urls.filter { wanted.contains($0) }.sorted {
                (order[$0] ?? Int.max) < (order[$1] ?? Int.max)
            }
            guard !urls.isEmpty else { return nil }
            return PhotoEventGroup(id: group.id, title: group.title, urls: urls, date: group.date)
        }.sorted {
            (order[$0.urls.first!] ?? Int.max) < (order[$1.urls.first!] ?? Int.max)
        }
    }

    private func reload() {
        let requestID = UUID()
        reloadID = requestID
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

struct ThumbnailCell: View {
    let url: URL
    let title: String
    var photoCount: Int = 1
    var isSelecting: Bool = false
    var isSelected: Bool = false
    @State private var image: UIImage?
    @State private var loadTicket = UUID()
    @State private var loadOperation: BlockOperation?
    private let accessGeneration = VaultGate.shared.generation
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "SecureVault.thumbnails"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
        ZStack(alignment: .topTrailing) {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .opacity(isSelecting && !isSelected ? 0.55 : 1.0)
            } else {
                Color.gray.opacity(0.15)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
            }
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? .orange : .white)
                    .background(Circle().fill(Color.black.opacity(0.5)).frame(width: 22, height: 22))
                    .padding(6)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if photoCount > 1 {
                Label("\(photoCount)", systemImage: "photo.on.rectangle")
                    .font(.caption.bold()).padding(6).background(.black.opacity(0.7), in: Capsule()).padding(6)
            }
        }
        Text(title)
            .font(.caption2).foregroundColor(.white).lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            guard image == nil else { return }
            let ticket = UUID()
            loadTicket = ticket
            let url = self.url
            let generation = accessGeneration
            loadOperation?.cancel()
            let operation = BlockOperation()
            operation.addExecutionBlock { [weak operation] in
                guard operation?.isCancelled == false else { return }
                let thumbnail = FileStorageManager.shared.loadThumbnail(at: url, generation: generation)
                guard operation?.isCancelled == false else { return }
                DispatchQueue.main.async {
                    guard self.loadTicket == ticket, VaultGate.shared.generation == generation else { return }
                    self.image = thumbnail
                    self.loadOperation = nil
                }
            }
            loadOperation = operation
            Self.queue.addOperation(operation)
        }
        .onDisappear { loadOperation?.cancel(); loadOperation = nil; loadTicket = UUID(); image = nil }
    }
}
