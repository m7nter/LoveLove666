import Foundation
import Combine
import CoreLocation
import UIKit

/// Runs only while the camera is visible and the application is active.
/// All mutable state and capture decisions are confined to the main queue.
final class RestrictedPlacesMonitor: ObservableObject {
    static let shared = RestrictedPlacesMonitor()
    @Published private(set) var decision = CaptureZoneDecision.disabled
    private var snapshot: RestrictedPlacesSnapshot?
    private var task: URLSessionDataTask?
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
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 40
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
        requestID = nil; task?.cancel(); task = nil
    }

    private func tick() {
        guard active else { return }
        let settings = SettingsStore.shared.restrictedPlaces
        guard settings.enabled else {
            cancelRequest(); snapshot = nil; nextRequest = .distantPast
            publish(.disabled); return
        }
        let location = LocationManager.shared.location.flatMap { $0.timestamp >= activationDate ? $0 : nil }
        let offlineSnapshot = location.flatMap { OfflinePlacesStore.shared.snapshot(for: $0, settings: settings) }
        let effectiveSnapshot = offlineSnapshot ?? snapshot
        var evaluated = RestrictedPlacesPolicy.evaluate(location: location, settings: settings, snapshot: effectiveSnapshot, unavailableReason: unavailableReason)
        if offlineSnapshot != nil && !evaluated.blocked { evaluated = .init(blocked: false, message: "Офлайн-проверка: запретных зон по сохранённым данным рядом не найдено") }
        publish(evaluated)
        if offlineSnapshot != nil { return }
        guard RestrictedPlaceKind.allCases.contains(where: settings.includes),
              RestrictedPlacesPolicy.locationProblem(location, settings: settings, now: Date()) == nil,
              let location, task == nil, Date() >= nextRequest else { return }
        let covered = snapshot?.covers(location, settings: settings, now: Date()) == true
        let shouldRefresh = !covered || snapshot.map { Date().timeIntervalSince($0.fetchedAt) > 480 || $0.center.distance(from: location) > 250 } == true
        guard shouldRefresh else { return }
        fetch(near: location, radius: settings.maximumRadius + 1000)
    }

    private func publish(_ newValue: CaptureZoneDecision) {
        if decision != newValue { decision = newValue }
    }

    static func query(near location: CLLocation, radius: Double) -> String {
        let lat = String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), location.coordinate.latitude)
        let lon = String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), location.coordinate.longitude)
        // is_in + pivot also finds a large enclosing territory whose fence lies
        // outside the search circle. Full geometry is essential for edge distance.
        let filters = [
            "[amenity~\"^(school|kindergarten|police|courthouse|townhall)$\"]",
            "[building~\"^(school|kindergarten)$\"]",
            "[leisure~\"^(playground|pitch|sports_centre|stadium|fitness_station|track)$\"]",
            "[office=government]", "[government]", "[police]", "[landuse=military]", "[military]"
        ]
        let around = "(around:\(Int(ceil(radius))),\(lat),\(lon))"
        let selections = filters.map { "nwr\(around)\($0); nwr(pivot.enclosing)\($0);" }.joined(separator: "\n")
        return "[out:json][timeout:25][maxsize:16777216];is_in(\(lat),\(lon))->.enclosing;(\(selections));out body geom;"
    }

    private func fetch(near center: CLLocation, radius: Double) {
        let id = UUID(); requestID = id
        var request = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!)
        request.httpMethod = "POST"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.query(near: center, radius: radius).data(using: .utf8)
        task = session.dataTask(with: request) { [weak self] data, response, error in
            let result: Result<[RestrictedPlace], Error> = Result {
                guard error == nil, let response = response as? HTTPURLResponse,
                      response.statusCode == 200, let data, data.count <= 16_777_216 else {
                    throw error ?? URLError(.badServerResponse)
                }
                return try RestrictedPlacesParser.parse(data)
            }
            DispatchQueue.main.async {
                guard let self, self.active, self.requestID == id else { return }
                self.task = nil; self.requestID = nil
                switch result {
                case .success(let places):
                    self.snapshot = .init(center: center, radius: radius, fetchedAt: Date(), places: places)
                    self.failureCount = 0; self.nextRequest = Date().addingTimeInterval(30)
                    self.unavailableReason = "Проверяем ближайшие территории…"
                case .failure(let error):
                    self.failureCount += 1
                    self.nextRequest = Date().addingTimeInterval(min(300, 30 * pow(2, Double(min(4, self.failureCount - 1)))))
                    if error is RestrictedPlacesError || error is DecodingError {
                        self.unavailableReason = "OpenStreetMap вернул неполные данные о территориях. Проверка повторится автоматически."
                    } else {
                        self.unavailableReason = "Не удалось проверить объекты OpenStreetMap. Проверьте интернет; повторим автоматически."
                    }
                }
                self.tick()
            }
        }
        task?.resume()
    }
}
