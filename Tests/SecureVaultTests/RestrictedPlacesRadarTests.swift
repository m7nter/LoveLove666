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
        let places = (1...5).map { place("school-\($0)", kind: .school, north: Double($0) * 100) }
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
