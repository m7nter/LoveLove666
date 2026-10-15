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

final class OfflineMapManager: ObservableObject {
    static let shared = OfflineMapManager()
    @Published private(set) var regions = OfflineRegion.bundled
    @Published private(set) var suggestedRegionID: String?
    @Published private(set) var suggestion = "Определяем регион по GPS…"
    @Published private(set) var rows: [OfflineDownloadRow] = []
    @Published private(set) var downloadingPlacesID: String?
    @Published var error: String?
    private var subscriptions: Set<AnyCancellable> = []
    private var packsObservation: NSKeyValueObservation?
    private var request: URLSessionDataTask?
    private var requestID: UUID?
    private var requestGeneration: Int?
    // Place data is fetched in bounded tiles. A whole oblast can be too large
    // for one Overpass response even though the MapLibre tile pack succeeds.
    private var placeRegion: OfflineRegion?
    private var placeTiles: [OfflineRegionBounds] = []
    private var placeTileIndex = 0
    private var placeResults: [String: RestrictedPlace] = [:]
    private let geocoder = CLGeocoder()
    private var lastSuggestion: Date = .distantPast
    private var initialized = false
    private var suggestionAttempts = 0
    private var blockedPacks: Set<String> = []
    private let session: URLSession

    private struct PackContext: Codable { let region: OfflineRegion; let zoom: Int; let date: Date }
    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 200; config.timeoutIntervalForResource = 220
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
            let ready = mapReady && dataset?.isCurrent == true
            let status: String
            if blockedPacks.contains(context.region.id) { status = "Достигнут лимит размера. Удалите и выберите меньшую детализацию." }
            else if ready { status = "Карта и зоны готовы · объекты \(dataset!.date.formatted(date: .numeric, time: .omitted))" }
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
            if OfflinePlacesStore.shared.dataset(for: id)?.isCurrent != true { downloadPlaces(context.region) }
        }
        refresh()
    }
    func pauseAll() {
        requestID = nil; request?.cancel(); request = nil; downloadingPlacesID = nil
        placeRegion = nil; placeTiles = []; placeTileIndex = 0; placeResults = [:]
        guard initialized else { return }
        MLNOfflineStorage.shared.packs?.filter { $0.state == .active }.forEach { $0.suspend() }
        refresh()
    }
    func remove(_ id: String) {
        if downloadingPlacesID == id {
            requestID = nil; request?.cancel(); request = nil; downloadingPlacesID = nil
            placeRegion = nil; placeTiles = []; placeTileIndex = 0; placeResults = [:]
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
        let bounds = region.bounds.expanded(by: 1500)
        placeRegion = region
        placeTiles = Self.placeTiles(for: bounds)
        placeTileIndex = 0
        placeResults = [:]
        requestGeneration = VaultGate.shared.generation
        downloadingPlacesID = region.id
        fetchNextPlaceTile()
    }

    private static func placeTiles(for bounds: OfflineRegionBounds) -> [OfflineRegionBounds] {
        // Two-degree cells keep Overpass responses bounded while covering a
        // large oblast with enough overlap for territories on cell borders.
        let step = 2.0
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
                       "[leisure~\"^(playground|pitch|sports_centre|stadium|fitness_station|track)$\"]", "[office=government]", "[government]", "[police]", "[landuse=military]", "[military]"]
        let selections = filters.map { "nwr(\(bounds.overpass))\($0);" }.joined()
        return "[out:json][timeout:90][maxsize:33554432];(\(selections));out body geom;"
    }

    private func fetchNextPlaceTile() {
        guard let region = placeRegion,
              placeTileIndex < placeTiles.count,
              let generation = requestGeneration else {
            finishPlaceDownload()
            return
        }
        let bounds = placeTiles[placeTileIndex]
        placeTileIndex += 1
        let id = UUID(); requestID = id
        var r = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!)
        r.httpMethod = "POST"
        r.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        r.httpBody = Self.placeQuery(for: bounds).data(using: .utf8)
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
                    self.fetchNextPlaceTile()
                case .failure:
                    self.requestID = nil; self.downloadingPlacesID = nil
                    self.placeRegion = nil; self.placeTiles = []; self.placeResults = [:]
                    self.error = "Не удалось загрузить участок объектов OpenStreetMap. Карта сохранена, но для съёмки нужны данные зон. Нажмите «Продолжить / обновить зоны» при интернете."
                }
            }
        }
        request?.resume()
    }

    private func finishPlaceDownload() {
        guard let region = placeRegion, let generation = requestGeneration else { return }
        let dataset = OfflinePlaceDataset(region: region, bounds: region.bounds.expanded(by: 1500), date: Date(), places: Array(placeResults.values))
        requestID = nil; request = nil; placeRegion = nil; placeTiles = []; placeTileIndex = 0; placeResults = [:]
        OfflinePlacesStore.shared.install(dataset, generation: generation) { [weak self] error in
            self?.downloadingPlacesID = nil; self?.refresh()
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
