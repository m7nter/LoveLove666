import Foundation
import CoreLocation

struct OfflineRegionBounds: Codable, Equatable {
    let south: Double, west: Double, north: Double, east: Double
    var center: CLLocationCoordinate2D { .init(latitude: (south + north) / 2, longitude: (west + east) / 2) }
    func contains(_ coordinate: CLLocationCoordinate2D, margin: Double = 0) -> Bool {
        let latitudeMargin = margin / 110_000
        let longitudeMargin = margin / max(100, 110_000 * cos(coordinate.latitude * .pi / 180))
        return coordinate.latitude >= south + latitudeMargin && coordinate.latitude <= north - latitudeMargin
            && coordinate.longitude >= west + longitudeMargin && coordinate.longitude <= east - longitudeMargin
    }
    func expanded(by meters: Double) -> Self {
        let dy = meters / 110_000, dx = meters / max(100, 110_000 * cos(center.latitude * .pi / 180))
        return .init(south: max(-85, south - dy), west: max(-180, west - dx), north: min(85, north + dy), east: min(180, east + dx))
    }
    var overpass: String {
        [south, west, north, east].map { String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), $0) }.joined(separator: ",")
    }
    func tileCount(maxZoom: Int) -> Int {
        guard east > west, north > south, east - west < 180 else { return Int.max }
        var count = 0
        for z in 0...maxZoom {
            let n = pow(2.0, Double(z))
            func x(_ lon: Double) -> Int { Int(floor((lon + 180) / 360 * n)) }
            func y(_ lat: Double) -> Int {
                let r = min(85.05112878, max(-85.05112878, lat)) * .pi / 180
                return Int(floor((1 - log(tan(r) + 1 / cos(r)) / .pi) / 2 * n))
            }
            count += max(1, x(east) - x(west) + 1) * max(1, y(south) - y(north) + 1)
        }
        return count
    }
}

struct OfflineRegion: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let iso: String
    let bounds: OfflineRegionBounds
    static var bundled: [OfflineRegion] {
        guard let url = Bundle.main.url(forResource: "OfflineRegions", withExtension: "json"), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }
}

struct OfflinePlaceDataset: Codable {
    let region: OfflineRegion
    let bounds: OfflineRegionBounds
    let date: Date
    let places: [RestrictedPlace]
    var isCurrent: Bool { Date().timeIntervalSince(date) >= 0 && Date().timeIntervalSince(date) < 30 * 86400 }
    var snapshot: RestrictedPlacesSnapshot {
        .init(center: CLLocation(latitude: bounds.center.latitude, longitude: bounds.center.longitude),
              radius: 0, fetchedAt: date, places: places, offlineBounds: bounds)
    }
}

/// Geometry is public OSM data; downloaded region selection is stored with iOS
/// file protection. A completed dataset is installed atomically, never partially.
final class OfflinePlacesStore {
    static let shared = OfflinePlacesStore()
    private var datasets: [String: OfflinePlaceDataset] = [:]
    private var indices: [String: RestrictedPlaceIndex] = [:]
    private var loaded = false
    private let queue = DispatchQueue(label: "Calculator.offlinePlaces", qos: .utility)
    private let installLock = NSLock()
    private var pendingInstalls: [String: UUID] = [:]
    private var removedDatasetIDs: Set<String> = []
    private var root: URL { VaultDirectories.application.support.appendingPathComponent("OfflinePlaces", isDirectory: true) }
    private func loadIfNeeded() {
        guard !loaded else { return }; loaded = true
        let root = self.root, generation = VaultGate.shared.generation
        queue.async {
            var found: [(OfflinePlaceDataset, RestrictedPlaceIndex)] = []
            for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "json" {
                if let data = try? Data(contentsOf: url), let dataset = try? JSONDecoder().decode(OfflinePlaceDataset.self, from: data) {
                    found.append((dataset, RestrictedPlaceIndex(dataset.places)))
                }
            }
            DispatchQueue.main.async {
                guard generation == VaultGate.shared.generation else { return }
                for (dataset, index) in found where !self.removedDatasetIDs.contains(dataset.region.id) && (self.datasets[dataset.region.id].map({ $0.date < dataset.date }) ?? true) {
                    self.datasets[dataset.region.id] = dataset; self.indices[dataset.region.id] = index
                }
                NotificationCenter.default.post(name: .init("OfflinePlacesChanged"), object: nil)
            }
        }
    }
    func dataset(for id: String) -> OfflinePlaceDataset? { loadIfNeeded(); return datasets[id] }
    func install(_ dataset: OfflinePlaceDataset, generation: Int, completion: @escaping (Error?) -> Void) {
        let root = self.root
        let token = UUID()
        installLock.lock(); pendingInstalls[dataset.region.id] = token; installLock.unlock()
        queue.async {
            let result = Result { () -> RestrictedPlaceIndex in
                let data = try JSONEncoder().encode(dataset), index = RestrictedPlaceIndex(dataset.places)
                try VaultGate.shared.withAccess(generation: generation) {
                    self.installLock.lock(); defer { self.installLock.unlock() }
                    guard self.pendingInstalls[dataset.region.id] == token else { throw CocoaError(.userCancelled) }
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    try data.write(to: root.appendingPathComponent(dataset.region.id + ".json"), options: [.atomic, .completeFileProtection])
                }
                return index
            }
            DispatchQueue.main.async {
                do {
                    let index = try result.get()
                    self.installLock.lock()
                    let current = self.pendingInstalls[dataset.region.id] == token
                    self.installLock.unlock()
                    guard current else { throw CocoaError(.userCancelled) }
                    guard generation == VaultGate.shared.generation else { throw CocoaError(.fileReadNoPermission) }
                    self.removedDatasetIDs.remove(dataset.region.id)
                    self.loadIfNeeded(); self.datasets[dataset.region.id] = dataset; self.indices[dataset.region.id] = index
                    NotificationCenter.default.post(name: .init("OfflinePlacesChanged"), object: nil)
                    completion(nil)
                } catch { completion(error) }
            }
        }
    }
    func remove(_ id: String) throws {
        loadIfNeeded()
        installLock.lock(); defer { installLock.unlock() }
        pendingInstalls.removeValue(forKey: id)
        removedDatasetIDs.insert(id)
        let url = root.appendingPathComponent(id + ".json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        datasets.removeValue(forKey: id)
        indices.removeValue(forKey: id)
    }
    func clearMemory() {
        installLock.lock(); pendingInstalls = [:]; installLock.unlock()
        datasets = [:]; indices = [:]; loaded = false
    }
    func snapshot(for location: CLLocation, settings: RestrictedPlaceSettings) -> RestrictedPlacesSnapshot? {
        loadIfNeeded()
        guard let dataset = datasets.values.sorted(by: { $0.date > $1.date }).first(where: {
            $0.snapshot.covers(location, settings: settings, now: Date())
        }) else { return nil }
        var snapshot = dataset.snapshot
        snapshot.index = indices[dataset.region.id]
        return snapshot
    }
}
