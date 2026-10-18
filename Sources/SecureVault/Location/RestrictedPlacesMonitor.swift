import Foundation
import Combine
import CoreLocation
import UIKit

/// Runs only while the camera is visible and the application is active.
/// All mutable state and capture decisions are confined to the main queue.
final class RestrictedPlacesMonitor: ObservableObject {
    static let shared = RestrictedPlacesMonitor()
    @Published private(set) var decision = CaptureZoneDecision.disabled
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
        guard settings.enabled else {
            cancelRequest(); snapshot = nil; nextRequest = .distantPast
            publish(.disabled); return
        }
        let location = LocationManager.shared.location.flatMap { $0.timestamp >= activationDate ? $0 : nil }
        let offlineSnapshot = settings.checkMode == .online ? nil : location.flatMap {
            OfflinePlacesStore.shared.snapshot(for: $0, settings: settings)
        }
        let effectiveSnapshot = offlineSnapshot ?? (settings.checkMode == .offline ? nil : snapshot)
        if settings.checkMode == .offline, offlineSnapshot == nil {
            publish(.init(blocked: true, message: "Офлайн-база запретных зон не загружена или не покрывает эту точку. Съёмка заблокирована."))
            return
        }
        var evaluated = RestrictedPlacesPolicy.evaluate(location: location, settings: settings, snapshot: effectiveSnapshot, unavailableReason: unavailableReason)
        if offlineSnapshot != nil && !evaluated.blocked { evaluated = .init(blocked: false, message: "Офлайн-проверка: запретных зон по сохранённым данным рядом не найдено") }
        publish(evaluated)
        if offlineSnapshot != nil || settings.checkMode == .offline { return }
        guard RestrictedPlaceKind.allCases.contains(where: settings.includes),
              RestrictedPlacesPolicy.locationProblem(location, settings: settings, now: Date()) == nil,
              let location, requestTask == nil, Date() >= nextRequest else { return }
        let covered = snapshot?.covers(location, settings: settings, now: Date()) == true
        let shouldRefresh = !covered || snapshot.map { Date().timeIntervalSince($0.fetchedAt) > 480 || $0.center.distance(from: location) > 250 } == true
        guard shouldRefresh else { return }
        let radius = min(1500, max(250, settings.maximumRadius + settings.accuracyLimit + 200))
        fetch(near: location, radius: radius, settings: settings)
    }

    private func publish(_ newValue: CaptureZoneDecision) {
        if decision != newValue { decision = newValue }
    }

    static func query(near location: CLLocation, radius: Double) -> String {
        query(near: location, radius: radius, settings: nil)
    }

    private static func query(near location: CLLocation, radius: Double, settings: RestrictedPlaceSettings?) -> String {
        let lat = String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), location.coordinate.latitude)
        let lon = String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), location.coordinate.longitude)
        let enabled = settings.map { value in
            Set(RestrictedPlaceKind.allCases.filter { value.includes($0) })
        }
        func includes(_ kind: RestrictedPlaceKind) -> Bool { enabled?.contains(kind) ?? true }
        var filters: [String] = []
        if includes(.playground) { filters.append("[leisure=playground]") }
        if includes(.kindergarten) { filters += ["[amenity=kindergarten]", "[building=kindergarten]"] }
        if includes(.school) { filters += ["[amenity=school]", "[building=school]"] }
        if includes(.sports) { filters.append("[leisure~\"^(pitch|sports_centre|stadium|fitness_station|track)$\"]") }
        if includes(.police) { filters += ["[amenity=police]", "[police]", "[government=police]"] }
        if includes(.security) { filters.append("[government~\"^(security|intelligence)$\"]") }
        if includes(.administration) { filters += ["[amenity=townhall]", "[government=administrative]"] }
        if includes(.court) { filters += ["[amenity=courthouse]", "[government=court]"] }
        if includes(.prosecutor) { filters.append("[government=prosecutor]") }
        if includes(.recruitment) { filters.append("[government=recruitment]") }
        if includes(.military) { filters += ["[landuse=military]", "[military]"] }
        let governmentKind: [RestrictedPlaceKind] = [.police, .security, .administration, .court, .prosecutor, .recruitment, .military, .government]
        if governmentKind.contains(where: { includes($0) }) { filters += ["[office=government]", "[government]"] }
        // Avoid sending an invalid empty union when every kind was disabled.
        if filters.isEmpty { filters = ["[amenity=__disabled__]"] }
        filters = Array(Set(filters)).sorted()
        let around = "(around:\(Int(ceil(radius))),\(lat),\(lon))"
        // Match the proven desktop Awesome Coord request: bounded nearby
        // objects with full geometry. Keeping this query simple is critical on
        // mobile Overpass servers; the previous is_in/pivot branch could make
        // an otherwise healthy server reject the entire request.
        let selections = filters.map { "nwr\(around)\($0);" }.joined(separator: "\n")
        return "[out:json][timeout:10][maxsize:8388608];(\(selections));out tags geom;"
    }

    private static let overpassEndpoints = [
        URL(string: "https://overpass.private.coffee/api/interpreter")!,
        URL(string: "https://overpass.openstreetmap.fr/api/interpreter")!,
        URL(string: "https://overpass.kumi.systems/api/interpreter")!,
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://lz4.overpass-api.de/api/interpreter")!,
        URL(string: "https://z.overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.osm.ch/api/interpreter")!,
        URL(string: "https://overpass.nchc.org.tw/api/interpreter")!,
    ]

    private static func requestPlaces(session: URLSession, endpoint: URL, query: String) async throws -> [RestrictedPlace] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        request.httpBody = "data=\(encoded)".data(using: .utf8)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               data.count <= 16_777_216 {
                return try RestrictedPlacesParser.parse(data)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Retry below as GET. Some mobile gateways drop form POST bodies
            // even though ordinary HTTPS requests work normally.
        }

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        components.queryItems = [URLQueryItem(name: "data", value: query)]
        guard let getURL = components.url else { throw URLError(.badURL) }
        var fallback = URLRequest(url: getURL)
        fallback.httpMethod = "GET"
        fallback.setValue("application/json", forHTTPHeaderField: "Accept")
        fallback.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        fallback.timeoutInterval = 4
        let (data, response) = try await session.data(for: fallback)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count <= 16_777_216 else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Overpass HTTP \(status)"])
        }
        let parsed = try RestrictedPlacesParser.parse(data)
        var unique: [String: RestrictedPlace] = [:]
        for place in parsed { unique[place.id] = place }
        return Array(unique.values)
    }

    private static func requestPlacesFromAnyEndpoint(session: URLSession, query: String) async throws -> [RestrictedPlace] {
        try await withThrowingTaskGroup(of: [RestrictedPlace].self) { group in
            for endpoint in overpassEndpoints {
                group.addTask {
                    try await requestPlaces(session: session, endpoint: endpoint, query: query)
                }
            }

            var lastError: Error?
            var emptyResult: [RestrictedPlace]?
            var remaining = overpassEndpoints.count
            while remaining > 0 {
                remaining -= 1
                do {
                    if let result = try await group.next() {
                        // Do not let one healthy but incomplete server's empty
                        // response hide objects returned by another endpoint.
                        if !result.isEmpty {
                            group.cancelAll()
                            return result
                        }
                        // Keep waiting for every endpoint before accepting an
                        // empty result. A slow replica may still contain a
                        // nearby object; allowing capture on an early empty
                        // response would turn a transient replica difference
                        // into a false negative.
                        emptyResult = result
                    }
                } catch {
                    lastError = error
                }
            }
            if let emptyResult { return emptyResult }
            throw lastError ?? URLError(.cannotLoadFromNetwork)
        }
    }

    private func fetch(near center: CLLocation, radius: Double, settings: RestrictedPlaceSettings) {
        let id = UUID(); requestID = id
        let query = Self.query(near: center, radius: radius, settings: settings)
        let session = self.session
        unavailableReason = "Запрашиваем данные OpenStreetMap через Overpass…"
        lastCheckSummary = "Выполняем запрос к OpenStreetMap…"
        publish(.init(blocked: true, message: unavailableReason + " Съёмка временно заблокирована."))
        requestTask = Task { [weak self] in
            do {
                let places = try await Self.requestPlacesFromAnyEndpoint(session: session, query: query)
                try Task.checkCancellation()
                await MainActor.run { [weak self] in
                    guard let self, self.active, self.requestID == id else { return }
                    self.requestTask = nil; self.requestID = nil
                    self.snapshot = .init(center: center, radius: radius, fetchedAt: Date(), places: places)
                    self.lastCheckSummary = "Успешно: найдено объектов — \(places.count). Обновлено сейчас."
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

