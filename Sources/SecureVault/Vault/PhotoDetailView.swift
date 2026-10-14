import SwiftUI

struct PhotoDetailView: View {
    let urls: [URL]
    let initialIndex: Int
    let onDelete: (URL) -> Void

    @Environment(\.dismiss) var dismiss
    @State private var currentIndex: Int
    @State private var showEditor = false
    @State private var editorImage: UIImage?
    @State private var loadingEditor = false
    @State private var editorLoadError = false
    @State private var showDeleteConfirm = false
    @State private var showNoteEditor = false
    @State private var noteText: String = ""
    @State private var refreshToken = UUID()
    private let accessGeneration = VaultGate.shared.generation

    init(urls: [URL], initialIndex: Int, onDelete: @escaping (URL) -> Void) {
        self.urls = urls
        self.initialIndex = initialIndex
        self.onDelete = onDelete
        self._currentIndex = State(initialValue: initialIndex)
    }

    private var currentURL: URL? {
        guard !urls.isEmpty else { return nil }
        return urls[min(max(currentIndex, 0), urls.count - 1)]
    }

    var body: some View {
        let meta = currentURL.flatMap { FileStorageManager.shared.loadMeta(for: $0) }
        let note = meta?.note ?? ""
        return ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                    PhotoPageView(url: url, refreshToken: refreshToken)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button("Закрыть") { dismiss() }
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(8)
                    Spacer()
                    if urls.count > 1 {
                        Text("\(currentIndex + 1) из \(urls.count)")
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.5))
                            .cornerRadius(8)
                    }
                    Spacer()
                    HStack(spacing: 12) {
                        Button {
                            guard currentURL != nil else { dismiss(); return }
                            noteText = note
                            showNoteEditor = true
                        } label: {
                            Image(systemName: note.isEmpty ? "note" : "note.text")
                                .foregroundColor(note.isEmpty ? .white : .orange)
                                .padding(10)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        Button { openEditor() } label: {
                            Image(systemName: "pencil")
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        .disabled(loadingEditor)
                        .alert("Не удалось открыть фото", isPresented: $editorLoadError) {
                            Button("Закрыть", role: .cancel) {}
                        }
                        Button {
                            showDeleteConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                                .padding(10)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 60)

                Text(currentURL.map { FileStorageManager.shared.title(for: $0, meta: meta,
                    numberingMode: SettingsStore.shared.numberingMode) } ?? "Фото удалено")
                    .font(.caption).foregroundColor(.white)
                    .padding(8).background(Color.black.opacity(0.6)).cornerRadius(8)

                if !note.isEmpty {
                    HStack {
                        Image(systemName: "note.text")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text(note)
                            .font(.caption)
                            .foregroundColor(.white)
                            .lineLimit(2)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(8)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                if loadingEditor { ProgressView("Открытие фото…").tint(.orange) }

                Spacer()
            }
            .allowsHitTesting(true)
        }
        .sheet(isPresented: $showEditor, onDismiss: { editorImage = nil }) {
            if let url = currentURL, let img = editorImage {
                GalleryEditorView(image: img, url: url) { _ in
                    refreshToken = UUID()
                }
            }
        }
        .sheet(isPresented: $showNoteEditor) {
            PhotoNoteEditorView(text: noteText) { newText in
                guard let url = currentURL else { return false }
                let saved = FileStorageManager.shared.updateNote(for: url, note: newText, generation: accessGeneration)
                if saved { refreshToken = UUID() }
                return saved
            }
        }
        .alert("Удалить фото?", isPresented: $showDeleteConfirm) {
            Button("Удалить", role: .destructive) {
                guard let deletingURL = currentURL else { dismiss(); return }
                onDelete(deletingURL)
                dismiss()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Это действие нельзя отменить.")
        }
        .onChange(of: urls) { if $0.isEmpty { dismiss() } }
    }

    private func openEditor() {
        guard let url = currentURL, !loadingEditor else { return }
        loadingEditor = true
        let generation = accessGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = FileStorageManager.shared.loadImage(at: url)
            DispatchQueue.main.async {
                loadingEditor = false
                guard currentURL == url, VaultGate.shared.generation == generation else { return }
                if let loaded { editorImage = loaded; showEditor = true }
                else { editorLoadError = true }
            }
        }
    }
}

private struct PhotoPageView: View {
    let url: URL
    let refreshToken: UUID
    @State private var image: UIImage?
    @State private var isVisible = false
    @State private var loadTicket = UUID()
    @State private var loadOperation: BlockOperation?
    private let accessGeneration = VaultGate.shared.generation
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "SecureVault.photoPreview"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.black
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { isVisible = true; load() }
        .onChange(of: refreshToken) { _ in if isVisible { load() } }
        .onDisappear {
            isVisible = false
            loadOperation?.cancel(); loadOperation = nil
            loadTicket = UUID(); image = nil
        }
    }

    private func load() {
        let ticket = UUID()
        loadTicket = ticket
        image = nil
        let url = self.url
        let generation = accessGeneration
        loadOperation?.cancel()
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation] in
            guard operation?.isCancelled == false else { return }
            let preview = FileStorageManager.shared.loadThumbnail(at: url, maxPixelSize: 2560, generation: generation)
            guard operation?.isCancelled == false else { return }
            DispatchQueue.main.async {
                guard self.loadTicket == ticket, VaultGate.shared.generation == generation else { return }
                self.image = preview
                self.loadOperation = nil
            }
        }
        loadOperation = operation
        Self.queue.addOperation(operation)
    }
}

struct PhotoNoteEditorView: View {
    let text: String
    let onSave: (String) -> Bool
    @Environment(\.dismiss) var dismiss
    @State private var noteText: String = ""
    @State private var saveError = false

    var body: some View {
        NavigationView {
            Form {
                Section("Заметка к фото") {
                    TextEditor(text: $noteText)
                        .frame(minHeight: 200)
                }
            }
            .navigationTitle("Заметка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Отмена") { dismiss() }
                        .foregroundColor(.red)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Сохранить") {
                        if onSave(noteText) { dismiss() }
                        else { saveError = true }
                    }
                    .foregroundColor(.orange)
                }
            }
        }
        .onAppear { noteText = text }
        .alert("Заметка не сохранена", isPresented: $saveError) {
            Button("Закрыть", role: .cancel) {}
        } message: { Text("Проверьте свободное место и повторите сохранение.") }
    }
}
