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
                    Text("Сообщение передаётся вместе с фотографиями. Telegram может отправить его отдельно от альбома; координаты останутся доступными для копирования.")
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
