import SwiftUI

enum GalleryPresentation {
    static func eventCount(_ count: Int) -> String {
        let remainder = count % 100
        let word: String
        if (11...14).contains(remainder) { word = "событий" }
        else {
            switch count % 10 {
            case 1: word = "событие"
            case 2...4: word = "события"
            default: word = "событий"
            }
        }
        return "\(count) \(word)"
    }

    static func summary(events: Int, photos: Int) -> String {
        "\(eventCount(events)) · \(photos) фото"
    }

    static func date(_ date: Date, relative: Bool = false) -> String {
        let calendar = Calendar.current
        if relative {
            if calendar.isDateInToday(date) { return "Сегодня" }
            if calendar.isDateInYesterday(date) { return "Вчера" }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
            ? "d MMMM" : "d MMMM yyyy"
        return formatter.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// All gallery previews share the same bounded, cancellable loading queue.
/// A fixed viewport fits the complete image, including any appended footer.
struct VaultThumbnailView: View {
    let url: URL
    var maxPixelSize: Int = 640
    var refreshToken: UUID? = nil
    @State private var image: UIImage?
    @State private var isVisible = false
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
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.075)
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Image(systemName: "photo").font(.title3).foregroundStyle(.white.opacity(0.25))
                }
            }
        }
        .accessibilityHidden(true)
        .onAppear { isVisible = true; load() }
        .onChange(of: url) { _ in if isVisible { load() } }
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
        let pixelSize = maxPixelSize
        let generation = accessGeneration
        loadOperation?.cancel()
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation] in
            guard operation?.isCancelled == false else { return }
            let thumbnail = FileStorageManager.shared.loadThumbnail(at: url, maxPixelSize: pixelSize, generation: generation)
            guard operation?.isCancelled == false else { return }
            DispatchQueue.main.async {
                guard isVisible, loadTicket == ticket, VaultGate.shared.generation == generation else { return }
                image = thumbnail; loadOperation = nil
            }
        }
        loadOperation = operation
        Self.queue.addOperation(operation)
    }
}

struct GalleryEventCard: View {
    let url: URL
    let title: String
    let date: Date
    let photoCount: Int
    let isSelecting: Bool
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VaultThumbnailView(url: url)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    if photoCount > 1 {
                        Label("\(photoCount) фото", systemImage: "square.stack.fill")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(9)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if isSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(isSelected ? Color.orange : .white)
                            .background(.black.opacity(0.7), in: Circle()).padding(10)
                    }
                }
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(GalleryPresentation.time(date)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .background(Color(white: 0.115))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(isSelected ? Color.orange : .white.opacity(0.075), lineWidth: isSelected ? 2 : 1)
        }
        .background {
            if photoCount > 1 {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(.white.opacity(0.10)).padding(.horizontal, 8).offset(y: -5)
            }
        }
        .padding(.top, 6)
        .opacity(isSelecting && !isSelected ? 0.65 : 1)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

struct GalleryCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
