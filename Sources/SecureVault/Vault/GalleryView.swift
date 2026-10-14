import SwiftUI

private struct PhotoEventGroup: Identifiable {
    let id: String
    let title: String
    let urls: [URL]
}

private struct GalleryRecord {
    let url: URL
    let meta: PhotoMeta?
    let date: Date
    let folder: String
    let eventKey: String
}

struct GalleryView: View {
    @Environment(\.dismiss) var dismiss
    @State private var groupedPhotos: [PhotoEventGroup] = []
    @State private var photoTitles: [URL: String] = [:]
    @State private var eventKeys: [URL: String] = [:]
    @State private var photoDates: [URL: Date] = [:]
    @State private var reloadID = UUID()
    @State private var selectedURL: URL?
    @State private var showSettings = false
    @State private var sharingItems: [Any] = []
    @State private var showShareSheet = false
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
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 2)]

    private var totalCount: Int {
        groupedPhotos.reduce(0) { $0 + $1.urls.count }
    }

    var body: some View {
        NavigationView {
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
                        ForEach(groupedPhotos) { group in
                            let day = group.title
                            let urls = group.urls
                            Section {
                                LazyVGrid(columns: columns, spacing: 2) {
                                    ForEach(urls, id: \.self) { url in
                                        ThumbnailCell(
                                            url: url,
                                            title: photoTitles[url] ?? url.deletingPathExtension().lastPathComponent,
                                            isSelecting: isSelecting,
                                            isSelected: selectedURLs.contains(url)
                                        )
                                        .onTapGesture {
                                            if isSelecting {
                                                toggleSelection(url)
                                            } else {
                                                selectedURL = url
                                            }
                                        }
                                    }
                                }
                                .padding(.bottom, 8)
                            } header: {
                                HStack {
                                    Text("\(day) — \(urls.count) фото")
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
                        }
                    }
                }
            }
        }
        .onAppear { reload() }
        .onDisappear { reloadID = UUID() }
        .sheet(item: $selectedURL) { url in
            let flat = groupedPhotos.flatMap { $0.urls }
            let idx = flat.firstIndex(of: url) ?? 0
            PhotoDetailView(urls: flat, initialIndex: idx) { deletedURL in
                delete(url: deletedURL)
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: { reload() }) {
            SettingsView()
        }
        .sheet(isPresented: $showShareSheet, onDismiss: {
            sharingItems = []
            PhotoExporter.cleanupTemporaryExports()
        }) {
            ShareSheet(items: sharingItems)
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
        guard !urls.isEmpty, !isExporting else { return }
        let notes = settings.notesOnExport
        let numbering = settings.numberingMode

        guard SettingsStore.shared.exportAsZip else {
            isExporting = true
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try PhotoExporter.copies(of: urls, includeNotes: notes, generation: accessGeneration, numberingMode: numbering) }
                DispatchQueue.main.async {
                    isExporting = false
                    switch result {
                    case .success(let plainURLs): sharingItems = plainURLs; showShareSheet = true
                    case .failure(let error): operationError = "Экспорт не выполнен: \(error.localizedDescription)"
                    }
                }
            }
            return
        }

        isExporting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let zipURL = ZipExporter.exportDay(label: "Выбранные фото", urls: urls, includeNotes: notes, generation: accessGeneration, numberingMode: numbering)
            DispatchQueue.main.async {
                isExporting = false
                if let zipURL = zipURL {
                    sharingItems = [zipURL]
                    showShareSheet = true
                } else { operationError = "Не удалось создать архив. Проверьте свободное место." }
            }
        }
    }

    private func shareDay(day: String, urls: [URL]) {
        guard !urls.isEmpty, !isExporting else { return }
        let notes = settings.notesOnExport
        let numbering = settings.numberingMode

        guard SettingsStore.shared.exportAsZip else {
            isExporting = true
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try PhotoExporter.copies(of: urls, includeNotes: notes, generation: accessGeneration, numberingMode: numbering) }
                DispatchQueue.main.async {
                    isExporting = false
                    switch result {
                    case .success(let plainURLs): sharingItems = plainURLs; showShareSheet = true
                    case .failure(let error): operationError = "Экспорт не выполнен: \(error.localizedDescription)"
                    }
                }
            }
            return
        }

        isExporting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let zipURL = ZipExporter.exportDay(label: day, urls: urls, includeNotes: notes, generation: accessGeneration, numberingMode: numbering)
            DispatchQueue.main.async {
                isExporting = false
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
            var events: [String: [GalleryRecord]] = [:]
            var order: [String] = []
            for record in records {
                counts[record.folder, default: 0] += 1
                titles[record.url] = storage.title(for: record.url, meta: record.meta, numberingMode: numberingMode)
                keys[record.url] = record.eventKey
                dates[record.url] = record.date
                if record.folder == folder {
                    if events[record.eventKey] == nil { order.append(record.eventKey) }
                    events[record.eventKey, default: []].append(record)
                }
            }
            let names = Set(["Без режима"] + modes + Array(counts.keys))
            let folderRows = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { ($0, counts[$0] ?? 0) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            formatter.dateFormat = "d MMMM yyyy"
            let groups = order.compactMap { key -> PhotoEventGroup? in
                guard let members = events[key]?.sorted(by: { ($0.meta?.eventIndex ?? 1) < ($1.meta?.eventIndex ?? 1) }),
                      let first = members.first else { return nil }
                let eventTitle = first.meta?.eventNumber.map { "Событие \($0)" } ?? "Отдельный снимок"
                let title = formatter.string(from: first.date) + " · " + eventTitle
                    + " · \(members.count)/\(first.meta?.eventCount ?? members.count)"
                return PhotoEventGroup(id: key, title: title, urls: members.map { $0.url })
            }
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
                    .scaledToFill()
                    .frame(width: 110, height: 110)
                    .clipped()
                    .opacity(isSelecting && !isSelected ? 0.55 : 1.0)
            } else {
                Color.gray.opacity(0.15)
                    .frame(width: 110, height: 110)
            }
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? .orange : .white)
                    .background(Circle().fill(Color.black.opacity(0.5)).frame(width: 22, height: 22))
                    .padding(6)
            }
        }
        Text(title)
            .font(.caption2).foregroundColor(.white).lineLimit(3)
            .frame(width: 110, alignment: .leading)
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
