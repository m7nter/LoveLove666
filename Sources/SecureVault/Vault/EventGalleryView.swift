import SwiftUI

struct EventGalleryView: View {
    let eventID: String
    let groups: [PhotoEventGroup]
    let photoTitles: [URL: String]
    let isExporting: Bool
    let onShare: (PhotoEventGroup) -> Void
    let onDelete: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var currentPhotoURL: URL?
    @State private var selectedURL: URL?
    @State private var revision = UUID()
    private var group: PhotoEventGroup? { groups.first { $0.id == eventID } }
    private var urls: [URL] { group?.urls ?? [] }
    private var currentIndex: Int { currentPhotoURL.flatMap { urls.firstIndex(of: $0) } ?? 0 }

    var body: some View {
        Group {
            if let group { eventContent(group) }
            else {
                VStack(spacing: 14) {
                    Image(systemName: "photo.on.rectangle").font(.largeTitle).foregroundStyle(.secondary)
                    Text("В событии больше нет фотографий").font(.headline).multilineTextAlignment(.center)
                    Button("К событиям") { dismiss() }.tint(.orange)
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(Color.black)
            .navigationTitle(group?.title ?? "Событие")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { if let group { onShare(group) } } label: {
                        if isExporting { ProgressView() }
                        else { Image(systemName: "square.and.arrow.up") }
                    }.tint(.orange).disabled(isExporting || group == nil).accessibilityLabel("Выгрузить событие")
                }
            }
            .onAppear { alignSelection() }
            .onChange(of: urls) { _ in alignSelection() }
            .sheet(item: $selectedURL, onDismiss: { revision = UUID() }) { url in
                PhotoDetailView(urls: urls, initialIndex: urls.firstIndex(of: url) ?? 0,
                    onSelectionChange: { currentPhotoURL = $0 }, onDelete: onDelete)
            }
    }

    private func eventContent(_ group: PhotoEventGroup) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("\(GalleryPresentation.date(group.date)) · \(GalleryPresentation.time(group.date))")
                    .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("event.date")
                Spacer(minLength: 4)
                Label("\(urls.count) фото", systemImage: "square.stack")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 16)

            TabView(selection: $currentPhotoURL) {
                ForEach(urls, id: \.self) { url in
                    Button { selectedURL = url } label: {
                        PhotoPageView(url: url, refreshToken: revision)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Открыть фото")
                    .accessibilityIdentifier("event.open." + url.lastPathComponent)
                    .tag(Optional(url))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.055))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 12)

            HStack {
                Text("\(currentIndex + 1) из \(urls.count)")
                    .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityIdentifier("event.position")
                Spacer()
                Button { selectedURL = currentPhotoURL ?? urls.first } label: {
                    Label("Открыть фото", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.footnote.weight(.medium)).frame(minHeight: 44)
                }.accessibilityIdentifier("event.openCurrent")
            }
            .padding(.horizontal, 20).padding(.top, 4)

            thumbnailStrip
        }.padding(.bottom, 10)
    }

    private var thumbnailStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(urls.enumerated()), id: \.element) { index, url in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { currentPhotoURL = url }
                        } label: {
                            VStack(spacing: 6) {
                                VaultThumbnailView(url: url, maxPixelSize: 220, refreshToken: revision)
                                    .frame(width: 54, height: 70)
                                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .strokeBorder(currentPhotoURL == url ? Color.orange : .white.opacity(0.15),
                                                          lineWidth: currentPhotoURL == url ? 2 : 1)
                                    }
                                Text("\(index + 1)").font(.caption2).monospacedDigit()
                                    .foregroundStyle(currentPhotoURL == url ? Color.orange : Color.secondary)
                            }.padding(.vertical, 4)
                        }
                        .buttonStyle(.plain).id(url)
                        .accessibilityLabel(photoTitles[url] ?? "Кадр \(index + 1)")
                        .accessibilityValue(currentPhotoURL == url ? "Текущий кадр" : "")
                        .accessibilityIdentifier("event.photo." + url.lastPathComponent)
                    }
                }.padding(.horizontal, 20)
            }
            .onChange(of: currentPhotoURL) { url in
                if let url { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(url, anchor: .center) } }
            }
        }
    }

    private func alignSelection() {
        if let currentPhotoURL, urls.contains(currentPhotoURL) { return }
        currentPhotoURL = urls.first
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
