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
    private let geocoder = CLGeocoder()
    private var lastSuggestion: Date = .distantPast
    private var initialized = false
    private var blockedPacks: Set<String> = []
    private let session: URLSession

    private struct PackContext: Codable { let region: OfflineRegion; let zoom: Int; let date: Date }
    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 200; config.timeoutIntervalForResource = 220
        config.httpAdditionalHeaders = ["User-Agent": "Calculator/1.2.0 (com.securevault.app)"]
        session = URLSession(configuration: config)
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
        // This is a one-shot system reverse geocode, not an Apple basemap.
        geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "ru_RU")) { [weak self] placemarks, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let placemark = placemarks?.first
                let names = [placemark?.administrativeArea, placemark?.subAdministrativeArea].compactMap { $0 }
                func normalized(_ s: String) -> String {
                    s.lowercased().replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: "область", with: "").replacingOccurrences(of: "республика", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let containing = self.regions.filter { $0.bounds.contains(location.coordinate) }
                let match = containing.first { region in names.contains { normalized(region.name) == normalized($0) } }
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
            let mapReady = pack.state == .complete
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
                if let pack { MLNOfflineStorage.shared.removePack(pack) { _ in } }; return
            }
            guard let self, let pack, error == nil else { self?.error = "Не удалось создать загрузку карты."; return }
            pack.resume(); self.refresh(); self.downloadPlaces(region)
        }
    }

    func resume(_ id: String) {
        guard !blockedPacks.contains(id) else { error = "Выберите меньшую детализацию после удаления этой загрузки."; return }
        if let pack = pack(for: id), let context = context(pack) {
            (MLNOfflineStorage.shared.packs ?? []).filter { $0 !== pack && $0.state == .active }.forEach { $0.suspend() }
            if pack.state != .complete { pack.resume() }
            if OfflinePlacesStore.shared.dataset(for: id)?.isCurrent != true { downloadPlaces(context.region) }
        }
        refresh()
    }
    func pauseAll() {
        requestID = nil; request?.cancel(); request = nil; downloadingPlacesID = nil
        guard initialized else { return }
        MLNOfflineStorage.shared.packs?.filter { $0.state == .active }.forEach { $0.suspend() }
        refresh()
    }
    func remove(_ id: String) {
        if downloadingPlacesID == id { requestID = nil; request?.cancel(); request = nil; downloadingPlacesID = nil }
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
        let filters = ["[amenity~\"^(school|kindergarten|police|courthouse|townhall)$\"]", "[building~\"^(school|kindergarten)$\"]",
                       "[leisure~\"^(playground|pitch|sports_centre|stadium|fitness_station|track)$\"]", "[office=government]", "[government]", "[police]", "[landuse=military]", "[military]"]
        let selections = filters.map { "nwr(\(bounds.overpass))\($0);nwr(pivot.enclosing)\($0);" }.joined()
        let lat = String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), bounds.center.latitude)
        let lon = String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), bounds.center.longitude)
        let query = "[out:json][timeout:180][maxsize:134217728];is_in(\(lat),\(lon))->.enclosing;(\(selections));out body geom;"
        var r = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!)
        r.httpMethod = "POST"; r.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type"); r.httpBody = query.data(using: .utf8)
        let id = UUID(), generation = VaultGate.shared.generation
        requestID = id; requestGeneration = generation; downloadingPlacesID = region.id
        request = session.dataTask(with: r) { [weak self] data, response, error in
            let result = Result { () -> OfflinePlaceDataset in
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200,
                      let data, data.count <= 134_217_728 else { throw error ?? URLError(.badServerResponse) }
                let places = try RestrictedPlacesParser.parse(data)
                return .init(region: region, bounds: bounds, date: Date(), places: places)
            }
            DispatchQueue.main.async {
                guard let self, self.requestID == id else { return }
                self.requestID = nil; self.request = nil; self.downloadingPlacesID = nil
                do {
                    let dataset = try result.get()
                    self.downloadingPlacesID = region.id
                    OfflinePlacesStore.shared.install(dataset, generation: generation) { [weak self] error in
                        self?.downloadingPlacesID = nil; self?.refresh()
                        if error != nil { self?.error = "Не удалось сохранить объекты региона. Проверьте свободное место." }
                    }
                } catch {
                    self.error = "Не удалось полностью загрузить объекты запретных зон. Карта сохраняется, но контроль без данных не разрешит съёмку. Нажмите «Продолжить / обновить зоны» для повтора."
                }
            }
        }
        request?.resume()
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
