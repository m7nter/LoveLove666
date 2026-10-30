import Foundation
import Combine
import CoreLocation
import UIKit

/// Runs only while the camera is visible and the application is active.
/// All mutable state and capture decisions are confined to the main queue.
final class RestrictedPlacesMonitor: ObservableObject {
    static let shared = RestrictedPlacesMonitor()
    @Published private(set) var decision = CaptureZoneDecision.disabled
    @Published private(set) var nearbyPlaces: [RestrictedPlaceSummary] = []
    @Published private(set) var radarPlaces: [RestrictedPlace] = []
    @Published private(set) var radarIsVerified = false
    @Published private(set) var radarRevision = 0
    private var radarSourceDate: Date?
    private var radarSourceIsOffline = false
    private var radarSettings: RestrictedPlaceSettings?
    @Published private(set) var lastCheckSummary = "Проверка ещё не выполнялась"
    private var snapshot: RestrictedPlacesSnapshot?
    private var requestTask: Task<Void, Never>?
    private var requestID: UUID?
    private var timer: AnyCancellable?
    private var subscriptions: Set<AnyCancellable> = []
    private var active = false
    private var activationDate = Date.distantPast
    private var nextRequest = Date.distantPast
    private var failureCount = 0
    private var previousKinds: Set<RestrictedPlaceKind>?
    private var unavailableReason = "Проверяем ближайшие территории…"
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        // A capture check must fail fast when an Overpass endpoint is stalled.
        // Waiting for connectivity here made a bad mobile/VPN route look like
        // a frozen camera for almost a minute.
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 18
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": "Calculator/1.2.0 (com.securevault.app)"]
        session = URLSession(configuration: config)
        LocationManager.shared.$location.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.tick() }.store(in: &subscriptions)
        SettingsStore.shared.$restrictedPlaces.receive(on: DispatchQueue.main).sink { [weak self] _ in
            // Published emits before assignment; receive(on:) applies after it.
            self?.tick()
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification).sink { [weak self] _ in self?.stop() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .vaultWillErase).receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.stop(); self?.snapshot = nil; OfflinePlacesStore.shared.clearMemory()
        }.store(in: &subscriptions)
    }

    func start() {
        if !active { activationDate = Date() }
        active = true
        if timer == nil {
            timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.tick() }
        }
        tick()
    }

    func stop() {
        active = false; timer?.cancel(); timer = nil
        cancelRequest()
        clearRadar()
    }

    func retryNow() {
        nextRequest = .distantPast
        failureCount = 0
        unavailableReason = "Запрашиваем данные OpenStreetMap через Overpass…"
        if active { tick() }
    }

    /// Called again by CameraViewModel immediately before AVFoundation capture.
    func captureDecision() -> CaptureZoneDecision {
        dispatchPrecondition(condition: .onQueue(.main))
        let settings = SettingsStore.shared.restrictedPlaces
        guard settings.enabled else { return .disabled }
        guard active, UIApplication.shared.applicationState == .active else {
            return .init(blocked: true, message: "Проверка зон приостановлена. Вернитесь в камеру.")
        }
        tick()
        return decision
    }

    private func cancelRequest() {
        requestID = nil; requestTask?.cancel(); requestTask = nil
    }

    private func tick() {
        guard active else { return }
        let settings = SettingsStore.shared.restrictedPlaces
        let enabledKinds = Set(RestrictedPlaceKind.allCases.filter(settings.includes))
        if let previousKinds, previousKinds != enabledKinds {
            // Invalidate a request made with the old switches immediately;
            // otherwise its answer could suppress newly enabled categories.
            cancelRequest()
            nextRequest = .distantPast
        }
        previousKinds = enabledKinds
        guard settings.enabled else {
            cancelRequest(); snapshot = nil; nextRequest = .distantPast
            clearRadar()
            publish(.disabled); return
        }
        let location = LocationManager.shared.location.flatMap { $0.timestamp >= activationDate ? $0 : nil }
        let offlineSnapshot = settings.checkMode == .online ? nil : location.flatMap {
            OfflinePlacesStore.shared.snapshot(for: $0, settings: settings)
        }
        // Automatic mode is online-first. A local snapshot is used only when
        // there is no currently usable online response, while the online
        // request is refreshed in the background. This keeps a stale offline
        // database from permanently masking newer OSM data.
        let onlineSnapshotIsUsable = location.flatMap { snapshot?.covers($0, settings: settings, now: Date()) } == true
        // Automatic mode is online-first. Do not present an old regional
        // snapshot while the first current request is still in flight: a
        // stale offline geometry can report a misleading distance (for
        // example, 150 m for an object that moved or was remapped). Offline
        // data becomes a fallback only after an actual online failure.
        let usingOfflineFallback = settings.checkMode == .offline
            || (settings.checkMode == .automatic && failureCount > 0 && !onlineSnapshotIsUsable && offlineSnapshot != nil)
        let effectiveSnapshot = usingOfflineFallback ? offlineSnapshot : (settings.checkMode == .offline ? nil : snapshot)
        updateRadar(snapshot: effectiveSnapshot, location: location, settings: settings)
        if settings.checkMode == .offline, offlineSnapshot == nil {
            if let location, OfflinePlacesStore.shared.requiresSafetyUpdate(at: location) {
                publish(.init(blocked: true, message: "Обновите базу зон: исправлена проверка полноты данных. Откройте офлайн-карты и нажмите «Продолжить / обновить зоны». Скачанная карта сохранена."))
                return
            }
            publish(.init(blocked: true, message: "Офлайн-база запретных зон не загружена или не покрывает эту точку. Съёмка заблокирована."))
            return
        }
        var evaluated = RestrictedPlacesPolicy.evaluate(location: location, settings: settings, snapshot: effectiveSnapshot, unavailableReason: unavailableReason)
        if usingOfflineFallback && !evaluated.blocked {
            evaluated = .init(blocked: false, message: "Офлайн-проверка: запретных зон по сохранённым данным рядом не найдено", nearby: evaluated.nearby)
        }
        publish(evaluated)
        if settings.checkMode == .offline { return }
        guard RestrictedPlaceKind.allCases.contains(where: settings.includes),
              RestrictedPlacesPolicy.locationProblem(location, settings: settings, now: Date()) == nil,
              let location, requestTask == nil, Date() >= nextRequest else { return }
        let covered = snapshot?.covers(location, settings: settings, now: Date()) == true
        let shouldRefresh = !covered || snapshot.map { Date().timeIntervalSince($0.fetchedAt) > 480 || $0.center.distance(from: location) > 250 } == true
        guard shouldRefresh else { return }
        // Keep enough context for the camera to show the three nearest unique
        // categories, even when their protection radius is smaller (for
        // example, a police point 800 m away from the user).
        let radius = min(1500, max(1000, settings.maximumRadius + settings.accuracyLimit + 200))
        fetch(near: location, radius: radius, settings: settings, preserveDecision: effectiveSnapshot != nil)
    }

    private func publish(_ newValue: CaptureZoneDecision) {
        if decision != newValue { decision = newValue }
        if nearbyPlaces != newValue.nearby { nearbyPlaces = newValue.nearby }
    }

    private func clearRadar() {
        if radarIsVerified || !radarPlaces.isEmpty {
            radarPlaces = []; radarIsVerified = false; radarRevision += 1
        }
        radarSourceDate = nil; radarSettings = nil
    }

    private func updateRadar(snapshot: RestrictedPlacesSnapshot?, location: CLLocation?, settings: RestrictedPlaceSettings) {
        guard let places = RestrictedPlacesRadarPolicy.places(location: location, settings: settings, snapshot: snapshot),
              let snapshot else { clearRadar(); return }
        let isOffline = snapshot.offlineBounds != nil || snapshot.offlineCoverage != nil
        if !radarIsVerified || radarSourceDate != snapshot.fetchedAt || radarSourceIsOffline != isOffline
            || radarSettings != settings || radarPlaces.map(\.id) != places.map(\.id) {
            radarPlaces = places
            radarSourceDate = snapshot.fetchedAt; radarSourceIsOffline = isOffline; radarSettings = settings
            radarRevision += 1
        }
        if !radarIsVerified { radarIsVerified = true }
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Isolated UI-preview data; neither this entry point nor its launch flag
    /// exists in a device build. No live OSM/GPS request is made by the fixture.
    func seedRadarPreview() {
        let user = CLLocation(coordinate: .init(latitude: 55, longitude: 37), altitude: 0,
            horizontalAccuracy: 2, verticalAccuracy: 1, timestamp: Date())
        LocationManager.shared.location = user
        let places = [
            RestrictedPlace(id: "preview-playground", kind: .playground, name: "Детская площадка",
                point: .init(lat: 55.0004, lon: 37), lines: [], outerRings: [], innerRings: []),
            RestrictedPlace(id: "preview-kindergarten", kind: .kindergarten, name: "Детский сад",
                point: nil, lines: [], outerRings: [[.init(lat: 54.9994, lon: 37.002),
                    .init(lat: 55.0004, lon: 37.002), .init(lat: 55.0004, lon: 37.004),
                    .init(lat: 54.9994, lon: 37.004), .init(lat: 54.9994, lon: 37.002)]], innerRings: []),
            RestrictedPlace(id: "preview-school", kind: .school, name: "Школа",
                point: .init(lat: 55.002, lon: 36.998), lines: [], outerRings: [], innerRings: []),
            RestrictedPlace(id: "preview-police", kind: .police, name: "Участковый пункт полиции",
                point: .init(lat: 54.998, lon: 36.997), lines: [], outerRings: [], innerRings: [])
        ]
        let settings = RestrictedPlaceSettings(enabled: true)
        SettingsStore.shared.restrictedPlaces = settings
        let data = RestrictedPlacesSnapshot(center: user, radius: 1_500, fetchedAt: Date(), places: places)
        snapshot = data
        updateRadar(snapshot: data, location: user, settings: settings)
        publish(RestrictedPlacesPolicy.evaluate(location: user, settings: settings, snapshot: data))
        lastCheckSummary = "Данные для проверки интерфейса"
    }
    #endif

    static func query(near location: CLLocation, radius: Double) -> String {
        query(near: location, radius: radius, settings: nil)
    }

    static func query(near location: CLLocation, radius: Double, settings: RestrictedPlaceSettings?) -> String {
        let lat = String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), location.coordinate.latitude)
        let lon = String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), location.coordinate.longitude)
        let enabled = settings.map { value in
            Set(RestrictedPlaceKind.allCases.filter { value.includes($0) })
        }
        func includes(_ kind: RestrictedPlaceKind) -> Bool { enabled?.contains(kind) ?? true }
        var filters: [String] = []

        // Group values by tag so Overpass scans the same radius fewer times.
        // This keeps the returned objects unchanged while reducing latency on
        // mobile mirrors, especially for a city-sized 1 km query.
        func addRegex(_ key: String, _ values: [String]) {
            guard !values.isEmpty else { return }
            let escaped = values.map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: "|")
            filters.append("[\(key)~\"^(\(escaped))$\"]")
        }
        if includes(.playground) {
            filters += ["[leisure=playground]", "[playground]"]
        }
        // Earlier remote name patterns mixed Cyrillic/Latin character ranges
        // and were rejected by otherwise healthy mirrors. Query identifying
        // keys by existence within the same bounded area instead; the
        // authoritative
        // RestrictedPlaceKind.classify() applies the Russian aliases after
        // decoding the returned tags.
        let nameAliasKinds: [RestrictedPlaceKind] = [.playground, .police, .security, .administration, .prosecutor, .recruitment]
        if nameAliasKinds.contains(where: includes) {
            filters.append(contentsOf: RestrictedPlaceKind.identifyingNameKeys.map { "[\(quoteTagKey($0))]" })
        }
        var amenities: [String] = []
        if includes(.kindergarten) { amenities.append("kindergarten") }
        if includes(.school) { amenities.append("school") }
        if includes(.police) { amenities.append("police") }
        if includes(.administration) { amenities.append("townhall") }
        if includes(.court) { amenities.append("courthouse") }
        addRegex("amenity", amenities)
        var education: [String] = []
        if includes(.kindergarten) { education.append("kindergarten") }
        if includes(.school) { education.append("school") }
        addRegex("education", education)
        var buildings: [String] = []
        if includes(.kindergarten) { buildings.append("kindergarten") }
        if includes(.school) { buildings.append("school") }
        addRegex("building", buildings)
        if includes(.sports) { filters.append("[leisure~\"^(pitch|sports_centre|stadium|fitness_station|track)$\"]") }
        if includes(.police) { filters += ["[police]", "[government=police]"] }
        var government: [String] = []
        if includes(.security) { government += ["security", "intelligence"] }
        if includes(.administration) { government.append("administrative") }
        if includes(.court) { government.append("court") }
        if includes(.prosecutor) { government.append("prosecutor") }
        if includes(.recruitment) { government.append("recruitment") }
        if includes(.military) { government.append("military") }
        if includes(.police) { government.append("police") }
        addRegex("government", government)
        if includes(.military) { filters += ["[landuse=military]", "[military]"] }
        let governmentKind: [RestrictedPlaceKind] = [.police, .security, .administration, .court, .prosecutor, .recruitment, .military, .government]
        if governmentKind.contains(where: { includes($0) }) { filters += ["[office=government]", "[government]"] }
        // Avoid sending an invalid empty union when every kind was disabled.
        if filters.isEmpty { filters = ["[amenity=__disabled__]"] }
        filters = Array(Set(filters)).sorted()
        let around = "(around:\(Int(ceil(radius))),\(lat),\(lon))"
        // Keep the request bounded to nearby objects with full geometry.
        // Keeping this query simple is critical on
        // mobile Overpass servers; the previous is_in/pivot branch could make
        // an otherwise healthy server reject the entire request.
        let selections = filters.map { "nwr\(around)\($0);" }.joined(separator: "\n")
        return "[out:json][timeout:10][maxsize:8388608];(\(selections));out tags geom;"
    }

    private static func quoteTagKey(_ key: String) -> String {
        "\"" + key.replacingOccurrences(of: "\\\"", with: "\\\\\"") + "\""
    }

    private static let overpassEndpoints = OverpassConfiguration.worldwideEndpoints

    private struct OverpassResponse {
        let places: [RestrictedPlace]
        let endpoint: URL
    }

    private var endpointOrder: [URL] {
        let known = Self.overpassEndpoints
        let saved = UserDefaults.standard.stringArray(forKey: "osm.overpass.endpointOrder") ?? []
        let byString = Dictionary(uniqueKeysWithValues: known.map { ($0.absoluteString, $0) })
        var result = saved.compactMap { byString[$0] }
        result.append(contentsOf: known.filter { endpoint in !result.contains(endpoint) })
        return result
    }

    private func rememberSuccessfulEndpoint(_ endpoint: URL) {
        var ordered = endpointOrder
        ordered.removeAll { $0 == endpoint }
        ordered.insert(endpoint, at: 0)
        UserDefaults.standard.set(ordered.map(\.absoluteString), forKey: "osm.overpass.endpointOrder")
    }

    private static func requestPlaces(session: URLSession, endpoint: URL, query: String) async throws -> OverpassResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("Calculator/1.2.0 (com.securevault.app)", forHTTPHeaderField: "User-Agent")
        request.httpBody = OverpassConfiguration.formBody(query: query)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               data.count <= 16_777_216 {
                return .init(places: uniquePlaces(try RestrictedPlacesParser.parse(data)), endpoint: endpoint)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Retry below as GET. Some mobile gateways drop form POST bodies
            // even though ordinary HTTPS requests work normally.
        }

        try Task.checkCancellation()
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        components.queryItems = [URLQueryItem(name: "data", value: query)]
        guard let getURL = components.url else { throw URLError(.badURL) }
        var fallback = URLRequest(url: getURL)
        fallback.httpMethod = "GET"
        fallback.setValue("application/json", forHTTPHeaderField: "Accept")
        fallback.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        fallback.setValue("Calculator/1.2.0 (com.securevault.app)", forHTTPHeaderField: "User-Agent")
        fallback.timeoutInterval = 4
        let (data, response) = try await session.data(for: fallback)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count <= 16_777_216 else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Overpass HTTP \(status)"])
        }
        let parsed = try RestrictedPlacesParser.parse(data)
        return .init(places: uniquePlaces(parsed), endpoint: endpoint)
    }

    private static func uniquePlaces(_ places: [RestrictedPlace]) -> [RestrictedPlace] {
        var unique: [String: RestrictedPlace] = [:]
        unique.reserveCapacity(places.count)
        for place in places { unique[place.id] = place }
        return Array(unique.values)
    }

    private static func requestPlacesFromAnyEndpoint(session: URLSession, query: String,
                                                     endpoints: [URL]) async throws -> OverpassResponse {
        // A valid empty Overpass response is still a complete answer. Waiting
        // for every mirror before accepting [] made a quiet location take as
        // long as the slowest or unreachable endpoint (often 10–18 seconds).
        // Race a small primary set and accept the first valid response,
        // including an empty one. Backups are used only when every primary
        // endpoint fails, so a slow mirror cannot hold the camera hostage.
        func firstValid(from endpoints: ArraySlice<URL>) async throws -> OverpassResponse {
            guard !endpoints.isEmpty else { throw URLError(.cannotLoadFromNetwork) }
            return try await withThrowingTaskGroup(of: OverpassResponse.self) { group in
                for endpoint in endpoints {
                    group.addTask {
                        try await requestPlaces(session: session, endpoint: endpoint, query: query)
                    }
                }
                var lastError: Error?
                var remaining = endpoints.count
                while remaining > 0 {
                    remaining -= 1
                    do {
                        if let result = try await group.next() {
                            group.cancelAll()
                            return result
                        }
                    } catch {
                        lastError = error
                    }
                }
                throw lastError ?? URLError(.cannotLoadFromNetwork)
            }
        }

        do {
            return try await firstValid(from: endpoints.prefix(4))
        } catch {
            try Task.checkCancellation()
            return try await firstValid(from: endpoints.dropFirst(4))
        }
    }

    private func fetch(near center: CLLocation, radius: Double, settings: RestrictedPlaceSettings,
                      preserveDecision: Bool = false) {
        let id = UUID(); requestID = id
        let query = Self.query(near: center, radius: radius, settings: settings)
        let session = self.session
        let endpoints = endpointOrder
        unavailableReason = "Запрашиваем данные OpenStreetMap через Overpass…"
        lastCheckSummary = "Выполняем запрос к OpenStreetMap через \(endpoints.count) зеркал…"
        if !preserveDecision {
            publish(.init(blocked: true, message: unavailableReason + " Съёмка временно заблокирована."))
        }
        let startedAt = Date()
        requestTask = Task { [weak self] in
            do {
                let response = try await Self.requestPlacesFromAnyEndpoint(session: session, query: query, endpoints: endpoints)
                try Task.checkCancellation()
                await MainActor.run { [weak self] in
                    guard let self, self.active, self.requestID == id else { return }
                    self.requestTask = nil; self.requestID = nil
                    self.rememberSuccessfulEndpoint(response.endpoint)
                    self.snapshot = .init(center: center, radius: radius, fetchedAt: Date(), places: response.places,
                                          isEmptyOnlineResponse: response.places.isEmpty,
                                          queriedKinds: Set(RestrictedPlaceKind.allCases.filter(settings.includes)))
                    let elapsed = String(format: "%.1f", Date().timeIntervalSince(startedAt))
                    let server = response.endpoint.host ?? "Overpass"
                    self.lastCheckSummary = "Успешно: найдено объектов — \(response.places.count). \(server), \(elapsed) с."
                    self.failureCount = 0; self.nextRequest = Date().addingTimeInterval(30)
                    self.unavailableReason = "Проверяем ближайшие территории…"
                    self.tick()
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.active, self.requestID == id else { return }
                    self.requestTask = nil; self.requestID = nil
                    self.failureCount += 1
                    self.nextRequest = Date().addingTimeInterval(min(120, 10 * pow(2, Double(min(3, self.failureCount - 1)))))
                    if error is RestrictedPlacesError || error is DecodingError {
                        self.unavailableReason = "OpenStreetMap вернул неполные данные о территориях. Проверка повторится автоматически."
                    } else {
                        let detail = (error as NSError).localizedDescription
                        self.unavailableReason = "Сервер OpenStreetMap временно не ответил (\(detail)). Повторим автоматически."
                    }
                    self.lastCheckSummary = "Ошибка проверки: \(self.unavailableReason)"
                    self.tick()
                }
            }
        }
    }
}
