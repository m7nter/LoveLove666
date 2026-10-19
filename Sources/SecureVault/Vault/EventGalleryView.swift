import SwiftUI

struct EventGalleryView: View {
    let eventID: String
    let groups: [PhotoEventGroup]
    let photoTitles: [URL: String]
    let isExporting: Bool
    let onShare: (PhotoEventGroup) -> Void
    let onDelete: (URL) -> Void
    @State private var selectedURL: URL?
    @State private var revision = UUID()
    private var group: PhotoEventGroup? { groups.first { $0.id == eventID } }
    private let columns = [GridItem(.adaptive(minimum: 145), spacing: 12)]

    var body: some View {
        ScrollView {
            if let group {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(group.urls, id: \.self) { url in
                        Button { selectedURL = url } label: {
                            ThumbnailCell(url: url, title: photoTitles[url] ?? url.lastPathComponent)
                        }.buttonStyle(.plain).accessibilityIdentifier("event.photo." + url.lastPathComponent)
                    }
                }.id(revision).padding(12)
            } else {
                Text("В этом событии больше нет фотографий").foregroundStyle(.secondary).padding(24)
            }
        }.background(Color.black)
            .navigationTitle(group.map { "\($0.title) · \($0.urls.count) фото" } ?? "Событие")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("event.gallery")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { if let group { onShare(group) } } label: {
                        if isExporting { ProgressView() }
                        else { Image(systemName: "square.and.arrow.up") }
                    }.tint(.orange).disabled(isExporting || group == nil).accessibilityLabel("Выгрузить событие")
                }
            }
            .sheet(item: $selectedURL, onDismiss: { revision = UUID() }) { url in
                let urls = group?.urls ?? []
                PhotoDetailView(urls: urls, initialIndex: urls.firstIndex(of: url) ?? 0, onDelete: onDelete)
            }
    }
}

struct EventShareItem: Identifiable {
    let id: String
    let title: String
    let files: [URL]
    let caption: String
}

struct EventSharePlan: Identifiable {
    let id = UUID()
    let events: [EventShareItem]
    let finalMessage: String?
}

struct SequentialEventShareView: View {
    let plan: EventSharePlan
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var showingShare = false
    @State private var showingFinal = false

    private var currentItems: [Any] {
        if showingFinal { return plan.finalMessage.map { [$0 as Any] } ?? [] }
        guard plan.events.indices.contains(index) else { return [] }
        let event = plan.events[index]
        return PhotoExporter.shareItems(of: event.files) + [event.caption as Any]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if showingFinal {
                    Image(systemName: "list.number")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text("Список событий")
                        .font(.title3.bold())
                    Text("Все события уже отправлены. Нажмите «Отправить», чтобы передать общий список координат отдельным сообщением.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                } else if plan.events.indices.contains(index) {
                    let event = plan.events[index]
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text("Событие \(index + 1) из \(plan.events.count)")
                        .font(.title3.bold())
                    Text(event.title)
                        .foregroundStyle(.secondary)
                    Text(event.caption)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .padding(.horizontal)
                    Text("В Telegram откроется альбом из \(event.files.count) фото. После закрытия окна можно отправить следующее событие.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Отправить") { showingShare = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(currentItems.isEmpty)
                if !showingFinal {
                    Button("Пропустить событие") { advance() }
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .navigationTitle("Выгрузка в Telegram")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.orange)
        .onAppear {
            guard !plan.events.isEmpty else { showingFinal = true; return }
            showingShare = true
        }
        .sheet(isPresented: $showingShare, onDismiss: advance) {
            ShareSheet(items: currentItems)
        }
    }

    private func advance() {
        guard showingShare == false else { return }
        if showingFinal {
            dismiss()
            return
        }
        if index + 1 < plan.events.count {
            index += 1
            DispatchQueue.main.async { showingShare = true }
        } else if plan.finalMessage != nil {
            showingFinal = true
            DispatchQueue.main.async { showingShare = true }
        } else {
            dismiss()
        }
    }
}

struct CoordinateSharePreview: View {
    let items: [Any]
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var sharing = false
    @State private var copied = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(copied ? "Скопировано" : "Скопировать координаты") {
                        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: text]],
                            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
                        copied = true
                    }
                    Text("Фотографии события передаются одним пакетом. Telegram может оформить подпись отдельным текстом — это зависит от его Share Extension; координаты останутся доступными для копирования.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }.navigationTitle("Выгрузка с координатами").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) { Button("Закрыть") { dismiss() } }
                    ToolbarItem(placement: .navigationBarTrailing) { Button("Отправить") { sharing = true } }
                }
        }.preferredColorScheme(.dark).tint(.orange)
            .sheet(isPresented: $sharing) { ShareSheet(items: items) }
    }
}
