import XCTest
import CoreLocation
@testable import SecureVault

final class OfflinePlacesTests: XCTestCase {
    private let bounds = OfflineRegionBounds(south: 54, west: 36, north: 56, east: 38)
    private func position(_ lat: Double = 55, _ lon: Double = 37, accuracy: Double = 5) -> CLLocation {
        .init(coordinate: .init(latitude: lat, longitude: lon), altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 1, timestamp: Date())
    }
    private func place(_ lat: Double, _ lon: Double) -> RestrictedPlace {
        .init(id: "\(lat),\(lon)", kind: .school, name: nil, point: .init(lat: lat, lon: lon), lines: [], outerRings: [], innerRings: [])
    }
    func testOfflineSnapshotWorksWithoutInternetWithinThirtyDays() {
        var settings = RestrictedPlaceSettings(); settings.enabled = true
        let data = OfflinePlaceDataset(region: .init(id: "test", name: "Тест", iso: "", bounds: bounds), bounds: bounds,
                                       date: Date().addingTimeInterval(-86400), places: [])
        XCTAssertTrue(data.isCurrent)
        XCTAssertFalse(RestrictedPlacesPolicy.evaluate(location: position(), settings: settings, snapshot: data.snapshot).blocked)
        XCTAssertTrue(RestrictedPlacesPolicy.evaluate(location: position(57), settings: settings, snapshot: data.snapshot).blocked)
        XCTAssertTrue(RestrictedPlacesPolicy.evaluate(location: position(accuracy: 15), settings: settings, snapshot: data.snapshot).blocked)
        let old = OfflinePlaceDataset(region: data.region, bounds: bounds, date: Date().addingTimeInterval(-31 * 86400), places: [])
        XCTAssertFalse(old.isCurrent)
        XCTAssertTrue(RestrictedPlacesPolicy.evaluate(location: position(), settings: settings, snapshot: old.snapshot).blocked)
    }
    func testOfflineCoverageRequiresFullRadiusInsideDownloadedBounds() {
        XCTAssertTrue(bounds.contains(position().coordinate, margin: 1000))
        XCTAssertFalse(bounds.contains(position(54.0001).coordinate, margin: 1000))
        XCTAssertTrue(bounds.expanded(by: 1500).contains(position(54).coordinate, margin: 1015))
    }
    func testLegacyZoneIndexRequiresSafeRefreshEvenWhenRecentlyDownloaded() throws {
        let current = OfflinePlaceDataset(region: .init(id: "legacy-fixture", name: "Тест", iso: "", bounds: bounds),
                                          bounds: bounds, date: Date(), places: [])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        json.removeValue(forKey: "schemaVersion")
        json.removeValue(forKey: "source")
        let legacy = try JSONDecoder().decode(OfflinePlaceDataset.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(legacy.requiresSafetyUpdate)
        XCTAssertFalse(legacy.isCurrent)
        XCTAssertFalse(legacy.isComplete)
        XCTAssertFalse(legacy.snapshot.covers(position(), settings: .init(enabled: true), now: Date()))
        XCTAssertTrue(RestrictedPlacesPolicy.evaluate(location: position(), settings: .init(enabled: true), snapshot: legacy.snapshot).blocked)
    }

    func testRefreshedZoneIndexesKeepVerifiableSourceAcrossRelaunch() throws {
        for source in [OfflinePlaceDataset.Source.regionalPBF, .worldwideOverpass] {
            let fresh = OfflinePlaceDataset(region: .init(id: "source-fixture", name: "Тест", iso: "", bounds: bounds),
                                            bounds: bounds, date: Date(), places: [], source: source)
            let restored = try JSONDecoder().decode(OfflinePlaceDataset.self, from: JSONEncoder().encode(fresh))
            XCTAssertEqual(restored.source, source)
            XCTAssertEqual(restored.schemaVersion, OfflinePlaceDataset.currentSchemaVersion)
            XCTAssertFalse(restored.requiresSafetyUpdate)
            XCTAssertTrue(restored.isCurrent)
            XCTAssertTrue(restored.snapshot.covers(position(), settings: .init(enabled: true), now: Date()))
        }
    }
    func testPartialOfflineDatasetNeverClaimsFailedTilesAreChecked() {
        let successfulTile = OfflineRegionBounds(south: 54.5, west: 36.5, north: 55.5, east: 37.5)
        let region = OfflineRegion(id: "partial-coverage", name: "Частичная база", iso: "", bounds: bounds)
        let data = OfflinePlaceDataset(region: region, bounds: bounds, date: Date(), places: [],
                                       coverage: [successfulTile], failedTileCount: 1)
        var settings = RestrictedPlaceSettings(); settings.enabled = true
        XCTAssertFalse(data.isComplete)
        XCTAssertFalse(RestrictedPlacesPolicy.evaluate(location: position(55, 37), settings: settings, snapshot: data.snapshot).blocked)
        XCTAssertTrue(RestrictedPlacesPolicy.evaluate(location: position(55.8, 37.8), settings: settings, snapshot: data.snapshot).blocked)
    }
    func testIndexKeepsLargeContainingPolygonAndNearbyPoints() {
        let polygon = RestrictedPlace(id: "territory", kind: .kindergarten, name: nil, point: nil, lines: [],
            outerRings: [[.init(lat: 54, lon: 36), .init(lat: 54, lon: 38), .init(lat: 56, lon: 38), .init(lat: 56, lon: 36), .init(lat: 54, lon: 36)]], innerRings: [])
        let index = RestrictedPlaceIndex([polygon, place(55, 37), place(50, 30)])
        let nearby = index.near(position(), radius: 100)
        XCTAssertEqual(Set(nearby.map(\.id)), ["territory", "55.0,37.0"])
        XCTAssertEqual(polygon.distance(from: position()), 0)
    }
    func testIndexFindsPointAcrossAntimeridian() {
        let p = place(0, -179.999)
        XCTAssertTrue(RestrictedPlaceIndex([p]).near(position(0, 179.999), radius: 500).contains { $0.id == p.id })
    }
    func testRegionCatalogContainsSelectableNamesAndCoordinates() {
        let regions = OfflineRegion.bundled
        XCTAssertGreaterThan(regions.count, 70)
        XCTAssertEqual(Set(regions.map(\.id)).count, regions.count)
        XCTAssertTrue(regions.contains { $0.name.contains("Московская") })
        XCTAssertTrue(regions.allSatisfy { !$0.name.isEmpty && $0.bounds.north > $0.bounds.south })
    }
    func testTileEstimationAndDetailLevels() {
        XCTAssertGreaterThan(bounds.tileCount(maxZoom: 14), bounds.tileCount(maxZoom: 12))
        XCTAssertGreaterThan(bounds.tileCount(maxZoom: 12), bounds.tileCount(maxZoom: 10))
        XCTAssertLessThan(bounds.tileCount(maxZoom: 10), 200_000)
    }
    @MainActor func testDatasetPersistsAndReloadsWithoutNetwork() {
        let store = OfflinePlacesStore.shared
        let region = OfflineRegion(id: "test-offline-persistence", name: "Тест", iso: "", bounds: bounds)
        let dataset = OfflinePlaceDataset(region: region, bounds: bounds, date: Date(), places: [place(55, 37)])
        let installed = expectation(description: "Atomic installation")
        store.install(dataset, generation: VaultGate.shared.generation) { error in XCTAssertNil(error); installed.fulfill() }
        wait(for: [installed], timeout: 10)
        store.clearMemory()
        let reloaded = expectation(forNotification: .init("OfflinePlacesChanged"), object: nil)
        _ = store.dataset(for: region.id)
        wait(for: [reloaded], timeout: 10)
        XCTAssertEqual(store.dataset(for: region.id)?.places.count, 1)
        var settings = RestrictedPlaceSettings(); settings.enabled = true
        let snapshot = store.snapshot(for: position(), settings: settings)
        XCTAssertNotNil(snapshot?.index)
        XCTAssertTrue(RestrictedPlacesPolicy.evaluate(location: position(), settings: settings, snapshot: snapshot).blocked)
        try? store.remove(region.id)
    }
    @MainActor func testDeletingDuringInstallationCannotRestoreDeletedDataset() {
        let store = OfflinePlacesStore.shared
        let region = OfflineRegion(id: "test-offline-cancel", name: "Тест", iso: "", bounds: bounds)
        let dataset = OfflinePlaceDataset(region: region, bounds: bounds, date: Date(), places: [place(55, 37)])
        let finished = expectation(description: "Cancelled installation")
        store.install(dataset, generation: VaultGate.shared.generation) { error in XCTAssertNotNil(error); finished.fulfill() }
        try? store.remove(region.id)
        wait(for: [finished], timeout: 10)
        XCTAssertNil(store.dataset(for: region.id))
    }
}
