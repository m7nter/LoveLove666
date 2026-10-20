import Foundation
import Combine
import MapLibre
import CoreLocation
import UIKit

enum OpenStreetMapConfiguration {
    // VersaTiles publishes OSM data for local/offline use, without API keys.
    static let styleURL = URL(string: "https://tiles.versatiles.org/assets/styles/colorful/style.json")!
    private static var configured = false
    static func configure() {
        guard !configured else { return }; configured = true
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 4
        config.httpAdditionalHeaders = ["User-Agent": "Calculator/1.2.0 (com.securevault.app)"]
        MLNNetworkConfiguration.sharedManager.sessionConfiguration = config
    }
}

struct OfflineDownloadRow: Identifiable {
    let id: String, name: String, status: String
    let fraction: Double
    let ready: Bool
    let zoom: Int
    let bytes: UInt64
}

struct OfflinePlacesDownloadProgress: Equatable {
    let regionID: String
    let completedTiles: Int
    let totalTiles: Int
    let placesCount: Int
    let failedTiles: Int
    let currentTileLabel: String
    let serverLabel: String
    let phase: String
    let bytesReceived: Int64
    let expectedBytes: Int64

    var fraction: Double {
        if expectedBytes > 0 { return min(1, Double(bytesReceived) / Double(expectedBytes)) }
        guard totalTiles > 0 else { return 0 }
        return min(1, Double(completedTiles) / Double(totalTiles))
    }

    var bytesLabel: String? {
        guard bytesReceived > 0 || expectedBytes > 0 else { return nil }
        let formatter = ByteCountFormatter(); formatter.countStyle = .file
        let received = formatter.string(fromByteCount: bytesReceived)
        guard expectedBytes > 0 else { return received }
        return "\(received) из \(formatter.string(fromByteCount: expectedBytes))"
    }
}

final class OfflineMapManager: ObservableObject {
    static let shared = OfflineMapManager()
    @Published private(set) var regions = OfflineRegion.bundled
    @Published private(set) var suggestedRegionID: String?
    @Published private(set) var suggestion = "Определяем регион по GPS…"
    @Published private(set) var rows: [OfflineDownloadRow] = []
    @Published private(set) var downloadingPlacesID: String?
    @Published private(set) var placesProgress: OfflinePlacesDownloadProgress?
    @Published private(set) var placesActivity: [String] = []
    @Published var error: String?
    private var subscriptions: Set<AnyCancellable> = []
    private var packsObservation: NSKeyValueObservation?
    private var request: URLSessionDataTask?
    private var pbfTask: Task<Void, Never>?
    private var requestID: UUID?
    private var requestGeneration: Int?
    // Place data is fetched in bounded tiles. A whole oblast can be too large
    // for one Overpass response even though the MapLibre tile pack succeeds.
    private var placeRegion: OfflineRegion?
    private var placeTiles: [OfflineRegionBounds] = []
    private var placeTileIndex = 0
    private var placeEndpointIndex = 0
    private var placeRetryCount = 0
    private var placeResults: [String: RestrictedPlace] = [:]
    private var placeSuccessfulBounds: [OfflineRegionBounds] = []
    private var placeFailedTileCount = 0
    private var placeCurrentTileLabel = ""
    private var placeCurrentServerLabel = ""
    private var placePhase = ""
    private var placeBytesReceived: Int64 = 0
    private var placeExpectedBytes: Int64 = 0
    private let geocoder = CLGeocoder()
    private var lastSuggestion: Date = .distantPast
    private var initialized = false
    private var suggestionAttempts = 0
    private var blockedPacks: Set<String> = []
    private let session: URLSession
    private static let placeEndpoints = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.kumi.systems/api/interpreter")!,
        URL(string: "https://overpass.private.coffee/api/interpreter")!,
        URL(string: "https://overpass.openstreetmap.fr/api/interpreter")!,
        URL(string: "https://overpass.osm.ch/api/interpreter")!,
        URL(string: "https://overpass.nchc.org.tw/api/interpreter")!
    ]

    private struct PlacesCheckpoint: Codable {
        let generation: Int
        let region: OfflineRegion
        let tiles: [OfflineRegionBounds]
        let nextTileIndex: Int
        let places: [RestrictedPlace]
        let successfulBounds: [OfflineRegionBounds]
        let failedTileCount: Int
    }

    private struct PackContext: Codable { let region: OfflineRegion; let zoom: Int; let date: Date }
    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 200; config.timeoutIntervalForResource = 240
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": "Calculator/1.2.0 (com.securevault.app)"]
        session = URLSession(configuration: config)
        LocationManager.shared.$location.throttle(for: .seconds(10), scheduler: DispatchQueue.main, latest: true).sink { [weak self] _ in
            guard let self, self.initialized, self.suggestedRegionID == nil, self.suggestionAttempts < 3,
                  UIApplication.shared.applicationState == .active else { return }
            self.detectRegion()
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .init("MLNOfflinePackProgressChanged")).receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .init("MLNOfflinePackError")).receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.error = "Загрузка карты прервана сетью. Можно продолжить после восстановления интернета."
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .init("OfflinePlacesChanged")).receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification).sink { [weak self] _ in self?.pauseAll() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .vaultWillErase).receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.pauseAll(); self?.geocoder.cancelGeocode()
            OfflinePlacesStore.shared.clearMemory()
        }.store(in: &subscriptions)
    }

    func open() {
        LocationManager.shared.requestAndStart()
        if !initialized {
            initialized = true; OpenStreetMapConfiguration.configure()
            packsObservation = MLNOfflineStorage.shared.observe(\.packs, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.refresh()
                    MLNOfflineStorage.shared.packs?.forEach { $0.requestProgress() }
                }
            }
        }
        refresh(); detectRegion()
    }

    func detectRegion() {
        guard Date().timeIntervalSince(lastSuggestion) > 10 else { return }
        guard let location = LocationManager.shared.location, abs(location.timestamp.timeIntervalSinceNow) < 60,
              location.horizontalAccuracy >= 0 else {
            suggestion = "Нет свежего GPS. Выберите регион из списка или повторите определение."; return
        }
        lastSuggestion = Date(); suggestion = "Определяем регион…"
        suggestionAttempts += 1
        // This is a one-shot system reverse geocode, not an Apple basemap.
        geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "ru_RU")) { [weak self] placemarks, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let placemark = placemarks?.first
                let names = [placemark?.administrativeArea, placemark?.subAdministrativeArea].compactMap { $0 }
                func normalized(_ s: String) -> String {
                    s.lowercased().replacingOccurrences(of: "ё", with: "е")
                        .replacingOccurrences(of: "область|обл\\.|республика|респ\\.", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let containing = self.regions.filter { $0.bounds.contains(location.coordinate) }
                let candidates = containing.filter { region in names.contains {
                    let name = normalized($0), candidate = normalized(region.name)
                    return name.count >= 4 && (candidate == name || candidate.hasPrefix(name + " ") || name.hasPrefix(candidate + " "))
                } }
                let match = candidates.count == 1 ? candidates.first : nil
                // A bounding box alone is not enough to disambiguate neighbours.
                if let match {
                    self.suggestedRegionID = match.id; self.suggestion = "По GPS: \(match.name)"
                } else {
                    self.suggestedRegionID = nil
                    self.suggestion = names.first.map { "По GPS: \($0). Уточните регион в списке." } ?? "Не удалось точно определить регион. Выберите его в списке."
                }
            }
        }
    }

    private func context(_ pack: MLNOfflinePack) -> PackContext? { try? JSONDecoder().decode(PackContext.self, from: pack.context) }
    private func pack(for id: String) -> MLNOfflinePack? {
        MLNOfflineStorage.shared.packs?.first { context($0)?.region.id == id }
    }

    func refresh() {
        guard initialized else { return }
        rows = (MLNOfflineStorage.shared.packs ?? []).compactMap { pack in
            guard pack.state != .invalid, let context = context(pack) else { return nil }
            let progress = pack.progress
            let dataset = OfflinePlacesStore.shared.dataset(for: context.region.id)
            let mapReady = pack.state == .complete && progress.countOfTilesCompleted > 0
            let ready = mapReady && dataset?.isCurrent == true && dataset?.isComplete == true
            let status: String
            if blockedPacks.contains(context.region.id) { status = "Достигнут лимит размера. Удалите и выберите меньшую детализацию." }
            else if ready { status = "Карта и зоны готовы · объекты \(dataset!.date.formatted(date: .numeric, time: .omitted))" }
            else if mapReady, let dataset, dataset.isCurrent { status = "Карта готова; зоны загружены частично (пропущено ячеек: \(dataset.failedTileCount ?? 0)). Можно продолжить загрузку." }
            else if mapReady && dataset == nil { status = "Карта готова; объекты запретных зон ещё не загружены" }
            else if mapReady { status = "Карта готова; обновите объекты запретных зон (старше 30 дней)" }
            else if pack.state == .active { status = "Загружено \(progress.countOfResourcesCompleted) из \(progress.countOfResourcesExpected) ресурсов" }
            else { status = "Загрузка карты приостановлена" }
            // Keep a deliberate device-storage ceiling; never call a partial map complete.
            if progress.countOfBytesCompleted > 2_000_000_000 || progress.countOfTilesCompleted > 200_000 {
                if pack.state == .active { pack.suspend() }
                blockedPacks.insert(context.region.id)
            }
            let fraction = progress.countOfResourcesExpected > 0 ? Double(progress.countOfResourcesCompleted) / Double(progress.countOfResourcesExpected) : 0
            return .init(id: context.region.id, name: context.region.name, status: status,
                         fraction: mapReady ? 1 : min(0.99, fraction), ready: ready, zoom: context.zoom, bytes: progress.countOfBytesCompleted)
        }.sorted { $0.name < $1.name }
    }

    func download(_ region: OfflineRegion, zoom: Int) {
        open()
        guard pack(for: region.id) == nil else { resume(region.id); return }
        guard region.bounds.east - region.bounds.west < 180 else {
            error = "Этот регион пересекает 180-й меридиан. Скачивание такой области пока не поддерживается."; return
        }
        guard region.bounds.tileCount(maxZoom: zoom) <= 200_000 else {
            error = "Регион слишком большой для этой детализации. Выберите обзорную карту или уровень «Улицы»."; return
        }
        let bounds = MLNCoordinateBounds(sw: .init(latitude: region.bounds.south, longitude: region.bounds.west),
                                         ne: .init(latitude: region.bounds.north, longitude: region.bounds.east))
        let definition = MLNTilePyramidOfflineRegion(styleURL: OpenStreetMapConfiguration.styleURL, bounds: bounds, fromZoomLevel: 0, toZoomLevel: Double(zoom))
        let metadata = PackContext(region: region, zoom: zoom, date: Date())
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        let generation = VaultGate.shared.generation
        MLNOfflineStorage.shared.addPack(for: definition, withContext: data) { [weak self] pack, error in
            guard (try? VaultGate.shared.withAccess(generation: generation) { true }) == true else {
                if let pack, pack.state != .invalid { MLNOfflineStorage.shared.removePack(pack) { _ in } }; return
            }
            guard let self, let pack, error == nil else { self?.error = "Не удалось создать загрузку карты."; return }
            pack.resume(); self.refresh(); self.downloadPlaces(region)
        }
    }

    func resume(_ id: String) {
        guard !blockedPacks.contains(id) else { error = "Выберите меньшую детализацию после удаления этой загрузки."; return }
        if let pack = pack(for: id), let context = context(pack) {
            (MLNOfflineStorage.shared.packs ?? []).filter { $0 !== pack && $0.state == .active }.forEach { $0.suspend() }
            if pack.state != .complete || pack.progress.countOfTilesCompleted == 0 { pack.resume() }
            if let dataset = OfflinePlacesStore.shared.dataset(for: id) {
                if dataset.isCurrent == false || dataset.isComplete == false { downloadPlaces(context.region) }
            } else { downloadPlaces(context.region) }
        }
        refresh()
    }
    func pauseAll() {
        savePlacesCheckpoint()
        requestID = nil; request?.cancel(); request = nil; pbfTask?.cancel(); pbfTask = nil; downloadingPlacesID = nil; placesProgress = nil
        placeRegion = nil; placeTiles = []; placeTileIndex = 0; placeEndpointIndex = 0; placeRetryCount = 0; placeResults = [:]
        placeSuccessfulBounds = []; placeFailedTileCount = 0
        placeCurrentTileLabel = ""; placeCurrentServerLabel = ""; placePhase = ""
        placeBytesReceived = 0; placeExpectedBytes = 0
        guard initialized else { return }
        MLNOfflineStorage.shared.packs?.filter { $0.state == .active }.forEach { $0.suspend() }
        refresh()
    }
    func remove(_ id: String) {
        if downloadingPlacesID == id {
            removePlacesCheckpoint(for: id)
            requestID = nil; request?.cancel(); request = nil; pbfTask?.cancel(); pbfTask = nil; downloadingPlacesID = nil; placesProgress = nil
            placeRegion = nil; placeTiles = []; placeTileIndex = 0; placeEndpointIndex = 0; placeRetryCount = 0; placeResults = [:]
            placeSuccessfulBounds = []; placeFailedTileCount = 0
            placeCurrentTileLabel = ""; placeCurrentServerLabel = ""; placePhase = ""
            placeBytesReceived = 0; placeExpectedBytes = 0
        }
        do { try OfflinePlacesStore.shared.remove(id) } catch { self.error = "Не удалось удалить объекты региона."; return }
        if let pack = pack(for: id) {
            pack.suspend()
            MLNOfflineStorage.shared.removePack(pack) { [weak self] error in
                self?.blockedPacks.remove(id); self?.refresh()
                if error != nil { self?.error = "Не удалось удалить карту региона." }
            }
        }
    }

    func downloadPlaces(_ region: OfflineRegion) {
        guard downloadingPlacesID == nil else { return }
        if let source = region.pbfSource, let url = URL(string: source.url) {
            downloadPlacesPBF(region, source: source, url: url)
            return
        }
        placeRegion = region
        let restored = restorePlacesCheckpoint(for: region)
        if !restored {
            let bounds = region.bounds.expanded(by: 1500)
            placeTiles = Self.placeTiles(for: bounds)
            placeTileIndex = 0
            placeResults = [:]
            placeSuccessfulBounds = []
            placeFailedTileCount = 0
        placeCurrentTileLabel = ""; placeCurrentServerLabel = ""; placePhase = ""
        placesActivity = []
        }
        placeEndpointIndex = 0
        placeRetryCount = 0
        requestGeneration = VaultGate.shared.generation
        downloadingPlacesID = region.id
        updatePlacesProgress()
        appendPlacesActivity("Начата загрузка зон для \(region.name): \(placeTiles.count) ячеек")
        fetchNextPlaceTile()
    }

    private func downloadPlacesPBF(_ region: OfflineRegion, source: OfflineZoneSource, url: URL) {
        let generation = VaultGate.shared.generation
        let id = UUID(); requestID = id; requestGeneration = generation
        downloadingPlacesID = region.id; placeRegion = region
        placeTiles = [region.bounds]; placeTileIndex = 0; placeFailedTileCount = 0
        placeResults = [:]; placeSuccessfulBounds = []
        placeCurrentTileLabel = "Региональная база PBF · \(source.size)"
        placeCurrentServerLabel = url.host ?? "Geo2Day"
        placePhase = "Скачиваем базу OSM"
        placeBytesReceived = 0; placeExpectedBytes = 0
        placesActivity = []
        updatePlacesProgress()
        appendPlacesActivity("Начата загрузка региональной базы \(source.name) · \(source.size)")
        let directory = checkpointDirectory
        let partialURL = directory.appendingPathComponent(".\(region.id).pbf.part")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existingBytes: Int64 = ((try? FileManager.default.attributesOfItem(atPath: partialURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("Calculator/1.2.0 (com.securevault.app)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 240
        if existingBytes > 0 { request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range") }
        pbfTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (bytes, response) = try await self.session.bytes(for: request)
                guard let http = response as? HTTPURLResponse,
                      http.statusCode == 200 || (http.statusCode == 206 && existingBytes > 0) else {
                    throw URLError(.badServerResponse)
                }
                let append = http.statusCode == 206 && existingBytes > 0
                let startBytes = append ? existingBytes : 0
                if !append {
                    FileManager.default.createFile(atPath: partialURL.path, contents: nil)
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: partialURL.path)
                }
                let handle = try FileHandle(forWritingTo: partialURL)
                if append { try handle.seekToEnd() } else { try handle.truncate(atOffset: 0) }
                defer { try? handle.close() }
                let contentLength = response.expectedContentLength
                let totalBytes = contentLength > 0 ? startBytes + contentLength : -1
                var receivedBytes = startBytes
                var buffer = Data(); buffer.reserveCapacity(256 * 1024)
                await MainActor.run {
                    self.placeBytesReceived = startBytes; self.placeExpectedBytes = totalBytes
                    self.placePhase = append ? "Продолжаем загрузку базы OSM" : "Скачиваем базу OSM"
                    self.updatePlacesProgress()
                }
                for try await byte in bytes {
                    try Task.checkCancellation()
                    buffer.append(byte)
                    if buffer.count >= 256 * 1024 {
                        try handle.write(contentsOf: buffer); receivedBytes += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                        let progressBytes = receivedBytes
                        await MainActor.run {
                            guard self.requestID == id else { return }
                            self.placeBytesReceived = progressBytes; self.updatePlacesProgress()
                        }
                    }
                }
                if !buffer.isEmpty { try handle.write(contentsOf: buffer); receivedBytes += Int64(buffer.count) }
                guard totalBytes <= 0 || receivedBytes == totalBytes else {
                    throw URLError(.networkConnectionLost, userInfo: [NSLocalizedDescriptionKey: "получено \(receivedBytes) из \(totalBytes) байт"])
                }
                try Task.checkCancellation()
                await MainActor.run {
                    guard self.requestID == id, self.downloadingPlacesID == region.id else { return }
                    self.pbfTask = nil; self.placeBytesReceived = 0; self.placeExpectedBytes = 0
                    self.placePhase = "Индексируем объекты OSM"; self.updatePlacesProgress(); self.appendPlacesActivity("База скачана, строим локальный индекс")
                    self.indexPBF(partialURL: partialURL, region: region, generation: generation, requestID: id)
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard self.requestID == id else { return }
                    self.pbfTask = nil; self.request = nil; self.downloadingPlacesID = nil; self.placeRegion = nil; self.placesProgress = nil
                    self.error = "Не удалось продолжить загрузку региональной PBF-базы: \(error.localizedDescription)"
                    self.appendPlacesActivity("Ошибка скачивания PBF; частичный файл сохранён для повтора")
                }
            }
        }
    }

    private func indexPBF(partialURL: URL, region: OfflineRegion, generation: Int, requestID id: UUID) {
        let parseQueue = DispatchQueue.global(qos: .utility)
        parseQueue.async { [weak self] in
            guard let self else { return }
            do {
                let places = try OSMPBFPlaceParser.parse(url: partialURL) { completed, total in
                    DispatchQueue.main.async {
                        guard self.requestID == id else { return }
                        self.placeCurrentTileLabel = "Индекс OSM · \(Int(Double(completed) / Double(max(1, total)) * 100))%"
                        self.updatePlacesProgress()
                    }
                }
                let dataset = OfflinePlaceDataset(region: region, bounds: region.bounds.expanded(by: 1500), date: Date(), places: places)
                DispatchQueue.main.async {
                    guard self.requestID == id else { return }
                    self.appendPlacesActivity("Индекс готов: найдено \(places.count) объектов")
                    OfflinePlacesStore.shared.install(dataset, generation: generation) { error in
                        try? FileManager.default.removeItem(at: partialURL)
                        self.request = nil; self.requestID = nil; self.requestGeneration = nil; self.downloadingPlacesID = nil; self.placeRegion = nil; self.placesProgress = nil
                        if error == nil { self.appendPlacesActivity("Региональная база установлена без пропущенных ячеек") }
                        else { self.error = "Не удалось установить локальную OSM-базу." }
                        self.refresh()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    try? FileManager.default.removeItem(at: partialURL)
                    self.request = nil; self.requestID = nil; self.downloadingPlacesID = nil; self.placeRegion = nil; self.placesProgress = nil
                    self.error = "Не удалось разобрать региональную PBF-базу OSM: \(error.localizedDescription)"
                    self.appendPlacesActivity("Ошибка индексации PBF")
                }
            }
        }
    }

    private func updatePlacesProgress() {
        guard let region = placeRegion else { return }
        placesProgress = .init(regionID: region.id,
                               completedTiles: placeTileIndex,
                               totalTiles: placeTiles.count,
                               placesCount: placeResults.count,
                               failedTiles: placeFailedTileCount,
                               currentTileLabel: placeCurrentTileLabel,
                               serverLabel: placeCurrentServerLabel,
                               phase: placePhase,
                               bytesReceived: placeBytesReceived,
                               expectedBytes: placeExpectedBytes)
    }

    private func appendPlacesActivity(_ message: String) {
        let stamp = Date().formatted(date: .omitted, time: .shortened)
        placesActivity.append("\(stamp)  \(message)")
        if placesActivity.count > 80 { placesActivity.removeFirst(placesActivity.count - 80) }
    }

    private var checkpointDirectory: URL {
        VaultDirectories.application.support.appendingPathComponent("OfflinePlaces", isDirectory: true)
    }

    private func checkpointURL(for id: String) -> URL {
        checkpointDirectory.appendingPathComponent(".progress-\(id).json")
    }

    private func savePlacesCheckpoint() {
        guard let region = placeRegion,
              let generation = requestGeneration,
              generation == VaultGate.shared.generation,
              placeTileIndex < placeTiles.count else { return }
        let checkpoint = PlacesCheckpoint(generation: generation, region: region, tiles: placeTiles,
                                          nextTileIndex: placeTileIndex, places: Array(placeResults.values),
                                          successfulBounds: placeSuccessfulBounds,
                                          failedTileCount: placeFailedTileCount)
        guard let data = try? JSONEncoder().encode(checkpoint) else { return }
        try? VaultGate.shared.withAccess(generation: generation) {
            try FileManager.default.createDirectory(at: checkpointDirectory, withIntermediateDirectories: true)
            try data.write(to: checkpointURL(for: region.id), options: [.atomic, .completeFileProtection])
        }
    }

    @discardableResult
    private func restorePlacesCheckpoint(for region: OfflineRegion) -> Bool {
        let url = checkpointURL(for: region.id)
        guard let data = try? Data(contentsOf: url),
              let checkpoint = try? JSONDecoder().decode(PlacesCheckpoint.self, from: data),
              checkpoint.generation == VaultGate.shared.generation,
              checkpoint.region.id == region.id,
              checkpoint.nextTileIndex < checkpoint.tiles.count else { return false }
        placeTiles = checkpoint.tiles
        placeTileIndex = checkpoint.nextTileIndex
        placeResults = Dictionary(uniqueKeysWithValues: checkpoint.places.map { ($0.id, $0) })
        placeSuccessfulBounds = checkpoint.successfulBounds
        placeFailedTileCount = checkpoint.failedTileCount
        return true
    }

    private func removePlacesCheckpoint(for id: String) {
        try? FileManager.default.removeItem(at: checkpointURL(for: id))
    }

    private static func placeTiles(for bounds: OfflineRegionBounds) -> [OfflineRegionBounds] {
        // 1.5° cells reduce the number of Overpass requests while keeping each
        // geometry response bounded. Failed cells are still retried on every
        // configured server and checkpointed for resume.
        let step = 1.5
        var result: [OfflineRegionBounds] = []
        var south = bounds.south
        while south < bounds.north {
            var west = bounds.west
            while west < bounds.east {
                result.append(.init(south: south, west: west,
                                    north: min(bounds.north, south + step),
                                    east: min(bounds.east, west + step)))
                west += step
            }
            south += step
        }
        return result
    }

    private static func placeQuery(for bounds: OfflineRegionBounds) -> String {
        let filters = ["[amenity~\"^(school|kindergarten|police|courthouse|townhall)$\"]", "[building~\"^(school|kindergarten)$\"]",
                       "[leisure~\"^(playground|pitch|sports_centre|stadium|fitness_station|track)$\"]", "[playground]", "[name~\"детск.*площадк|игров.*площадк\",i]", "[office=government]", "[government]", "[police]", "[landuse=military]", "[military]"]
        let selections = filters.map { "nwr(\(bounds.overpass))\($0);" }.joined()
        return "[out:json][timeout:90][maxsize:33554432];(\(selections));out tags geom;"
    }

    private func fetchNextPlaceTile() {
        guard let region = placeRegion,
              placeTileIndex < placeTiles.count,
              let generation = requestGeneration else {
            finishPlaceDownload()
            return
        }
        let bounds = placeTiles[placeTileIndex]
        let id = UUID(); requestID = id
        placeCurrentTileLabel = "Ячейка \(placeTileIndex + 1)/\(placeTiles.count) · \(String(format: "%.2f", bounds.center.latitude)), \(String(format: "%.2f", bounds.center.longitude))"
        placeCurrentServerLabel = Self.placeEndpoints[placeEndpointIndex].host ?? "OSM"
        placePhase = "Запрашиваем объекты"
        updatePlacesProgress()
        appendPlacesActivity("\(placeCurrentTileLabel) → \(placeCurrentServerLabel)")
        var r = URLRequest(url: Self.placeEndpoints[placeEndpointIndex])
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let query = Self.placeQuery(for: bounds)
        // All endpoints receive the same form-encoded request. The first
        // endpoint previously used plain text, which is rejected by some
        // mobile networks and inflated the visible failed-cell count.
        r.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        r.httpBody = "data=\(encoded)".data(using: .utf8)
        request = session.dataTask(with: r) { [weak self] data, response, error in
            let result: Result<[RestrictedPlace], Error> = Result {
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200,
                      let data, data.count <= 33_554_432 else { throw error ?? URLError(.badServerResponse) }
                return try RestrictedPlacesParser.parse(data)
            }
            DispatchQueue.main.async {
                guard let self, self.requestID == id, self.placeRegion?.id == region.id else { return }
                self.request = nil
                switch result {
                case .success(let places):
                    for place in places { self.placeResults[place.id] = place }
                    // Keep a conservative interior for offline verification;
                    // objects on a failed neighbouring tile must not be
                    // treated as absent near a tile edge.
                    self.placeSuccessfulBounds.append(bounds.inset(by: 250))
                    self.placeTileIndex += 1
                    self.placeEndpointIndex = 0
                    self.placeRetryCount = 0
                    self.placePhase = "Успешно"
                    self.updatePlacesProgress()
                    self.appendPlacesActivity("Готово: найдено объектов всего \(self.placeResults.count)")
                    self.savePlacesCheckpoint()
                    self.fetchNextPlaceTile()
                case .failure:
                    self.request = nil
                    if self.placeEndpointIndex + 1 < Self.placeEndpoints.count {
                        self.placeEndpointIndex += 1
                        self.placePhase = "Повторяем через другой сервер"
                        self.appendPlacesActivity("Ошибка ячейки, пробуем \(Self.placeEndpoints[self.placeEndpointIndex].host ?? "OSM")")
                        self.fetchNextPlaceTile()
                    } else if self.placeRetryCount < 1 {
                        self.placeRetryCount += 1
                        self.placeEndpointIndex = 0
                        self.placePhase = "Повторная попытка"
                        self.appendPlacesActivity("Все серверы не ответили, повторяем ячейку")
                        self.fetchNextPlaceTile()
                    } else {
                        // A single unavailable tile must not discard the
                        // successful part of a large oblast. The partial
                        // dataset records its covered rectangles and remains
                        // fail-closed outside them.
                        self.placeFailedTileCount += 1
                        self.placeTileIndex += 1
                        self.placeEndpointIndex = 0
                        self.placeRetryCount = 0
                        self.placePhase = "Пропущено"
                        self.updatePlacesProgress()
                        self.appendPlacesActivity("Ячейка пропущена после повторов")
                        self.savePlacesCheckpoint()
                        self.fetchNextPlaceTile()
                    }
                }
            }
        }
        request?.resume()
    }

    private func finishPlaceDownload() {
        guard let region = placeRegion, let generation = requestGeneration else { return }
        guard !placeResults.isEmpty || !placeSuccessfulBounds.isEmpty else {
            requestID = nil; request = nil; placeRegion = nil; placeTiles = []; placeTileIndex = 0; placeEndpointIndex = 0; placeRetryCount = 0; placeResults = [:]
            placeSuccessfulBounds = []; placeFailedTileCount = 0; downloadingPlacesID = nil; placesProgress = nil
            appendPlacesActivity("Не удалось получить ни одной ячейки")
            removePlacesCheckpoint(for: region.id)
            error = "Не удалось получить объекты запретных зон. Карта сохранена; повторите загрузку при доступном интернете."
            refresh()
            return
        }
        let complete = placeFailedTileCount == 0
        let dataset = OfflinePlaceDataset(region: region, bounds: region.bounds.expanded(by: 1500), date: Date(), places: Array(placeResults.values),
                                          coverage: complete ? nil : placeSuccessfulBounds,
                                          failedTileCount: complete ? nil : placeFailedTileCount)
        requestID = nil; request = nil; placeRegion = nil; placeTiles = []; placeTileIndex = 0; placeEndpointIndex = 0; placeRetryCount = 0; placeResults = [:]
        placeSuccessfulBounds = []; placeFailedTileCount = 0
        OfflinePlacesStore.shared.install(dataset, generation: generation) { [weak self] error in
        if error == nil { self?.removePlacesCheckpoint(for: region.id) }
        if error == nil { self?.appendPlacesActivity("Загрузка зон завершена: найдено \(dataset.places.count) объектов") }
        self?.downloadingPlacesID = nil; self?.placesProgress = nil; self?.refresh()
            if error != nil { self?.error = "Не удалось сохранить объекты региона. Проверьте свободное место." }
        }
    }

    /// Reset through the SDK, then preserve its now-empty SQLite directory while
    /// the vault erases files. Unlinking a live SQLite database can corrupt it.
    func prepareForErase(_ mode: ActionButtonMode, completion: @escaping (Error?) -> Void) {
        pauseAll(); OfflinePlacesStore.shared.clearMemory()
        guard mode != .photos else { completion(nil); return }
        OpenStreetMapConfiguration.configure()
        MLNOfflineStorage.shared.resetDatabase { [weak self] error in
            self?.rows = []; self?.blockedPacks = []
            completion(error)
        }
    }
}

