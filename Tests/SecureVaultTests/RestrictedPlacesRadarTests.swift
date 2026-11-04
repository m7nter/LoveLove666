import XCTest
import CoreLocation
@testable import SecureVault

final class RestrictedPlacesRadarTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func user(age: Double = 0, accuracy: Double = 1) -> CLLocation {
        .init(coordinate: .init(latitude: 55, longitude: 70), altitude: 0,
              horizontalAccuracy: accuracy, verticalAccuracy: 1, timestamp: now.addingTimeInterval(-age))
    }
    private func place(_ id: String, kind: RestrictedPlaceKind, north: Double) -> RestrictedPlace {
        .init(id: id, kind: kind, name: nil, point: .init(lat: 55 + north / 111_000, lon: 70),
              lines: [], outerRings: [], innerRings: [])
    }
    private func snapshot(_ places: [RestrictedPlace], age: Double = 0, empty: Bool = false) -> RestrictedPlacesSnapshot {
        .init(center: user(), radius: 1_500, fetchedAt: now.addingTimeInterval(-age),
              places: places, isEmptyOnlineResponse: empty)
    }
    func testAllNearbyObjectsAreShownRatherThanOnlyThreeCategorySummaries() throws {
        let places = (1...5).map { place("school-\($0)", kind: .school, north: Double($0) * 80) }
        let data = try XCTUnwrap(RestrictedPlacesRadarPolicy.places(location: user(),
            settings: .init(enabled: true), snapshot: snapshot(places), now: now))
        XCTAssertEqual(data.map(\.id), places.map(\.id))
    }
    func testUnverifiedAndVerifiedEmptyAreaRemainDistinct() {
        let settings = RestrictedPlaceSettings(enabled: true)
        XCTAssertNil(RestrictedPlacesRadarPolicy.places(location: user(), settings: settings, snapshot: nil, now: now))
        XCTAssertNil(RestrictedPlacesRadarPolicy.places(location: user(age: 16), settings: settings, snapshot: snapshot([]), now: now))
        XCTAssertNil(RestrictedPlacesRadarPolicy.places(location: user(accuracy: 15), settings: settings, snapshot: snapshot([]), now: now))
        XCTAssertNil(RestrictedPlacesRadarPolicy.places(location: user(), settings: settings, snapshot: snapshot([], age: 600), now: now))
        XCTAssertEqual(RestrictedPlacesRadarPolicy.places(location: user(), settings: settings, snapshot: snapshot([]), now: now)?.count, 0)
        var strict = settings; strict.blockOnEmptyOnlineResponse = true
        XCTAssertNil(RestrictedPlacesRadarPolicy.places(location: user(), settings: strict, snapshot: snapshot([], empty: true), now: now))
    }

    func testMovingThroughOfflineRegionReplacesPlaygroundsWithoutLimitingTheirCount() throws {
        let places = (0..<24).map { place("playground-\($0)", kind: .playground, north: Double($0) * 100) }
        let bounds = OfflineRegionBounds(south: 54.9, west: 69.9, north: 55.1, east: 70.1)
        let data = RestrictedPlacesSnapshot(center: user(), radius: 0, fetchedAt: now, places: places,
            offlineBounds: bounds, index: RestrictedPlaceIndex(places))
        let settings = RestrictedPlaceSettings(enabled: true)
        for north in [0.0, 800, 1_600] {
            let moved = CLLocation(coordinate: .init(latitude: 55 + north / 111_000, longitude: 70),
                altitude: 0, horizontalAccuracy: 1, verticalAccuracy: 1, timestamp: now)
            let expected = places.filter { $0.distance(from: moved) <= 500 }
                .sorted { $0.distance(from: moved) < $1.distance(from: moved) }.map(\.id)
            let visible = try XCTUnwrap(RestrictedPlacesRadarPolicy.places(location: moved, settings: settings,
                snapshot: data, now: now))
            XCTAssertEqual(visible.map(\.id), expected)
            XCTAssertGreaterThan(visible.count, 3)
        }
    }
    func testDisabledKindsAndDistantObjectsAreOmittedWithoutHidingNearbySchools() throws {
        let places = [place("school", kind: .school, north: 50), place("police", kind: .police, north: 100),
                      place("distant-school", kind: .school, north: 2_000)]
        var settings = RestrictedPlaceSettings(enabled: true); settings.disabledKinds.insert(.police)
        let data = try XCTUnwrap(RestrictedPlacesRadarPolicy.places(location: user(), settings: settings,
            snapshot: snapshot(places), now: now))
        XCTAssertEqual(data.map(\.id), ["school"])
    }
    func testRadarAndCameraRejectSameIncompleteCategoryCoverage() {
        let cached = RestrictedPlacesSnapshot(center: user(), radius: 1_500, fetchedAt: now,
            places: [place("school", kind: .school, north: 50)], queriedKinds: [.school])
        let settings = RestrictedPlaceSettings(enabled: true)
        XCTAssertTrue(RestrictedPlacesPolicy.evaluate(location: user(), settings: settings, snapshot: cached, now: now).blocked)
        XCTAssertNil(RestrictedPlacesRadarPolicy.places(location: user(), settings: settings, snapshot: cached, now: now))
    }
}
