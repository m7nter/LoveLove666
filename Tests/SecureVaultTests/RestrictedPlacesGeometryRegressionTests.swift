import XCTest
import CoreLocation
@testable import SecureVault

final class RestrictedPlacesGeometryRegressionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func location(_ latitude: Double, _ longitude: Double, accuracy: Double = 1) -> CLLocation {
        CLLocation(coordinate: .init(latitude: latitude, longitude: longitude), altitude: 0,
                   horizontalAccuracy: accuracy, verticalAccuracy: 1, timestamp: now)
    }

    private func coordinate(from origin: CLLocation, north: Double, east: Double) -> OSMCoordinate {
        let radians = Double.pi / 180
        return .init(lat: origin.coordinate.latitude + north / 6_371_000 / radians,
                     lon: origin.coordinate.longitude + east / (6_371_000 * cos(origin.coordinate.latitude * radians)) / radians)
    }

    func testAllTwelveCategoriesBlockInsideAndAllowOutsideAtDifferentLatitudes() {
        for latitude in [43.0, 60.0, 74.0] {
            let user = location(latitude, 70)
            let settings = RestrictedPlaceSettings(enabled: true)
            for kind in RestrictedPlaceKind.allCases {
                for inside in [true, false] {
                    let distance = kind.defaultRadius + (inside ? -8 : 8)
                    let point = coordinate(from: user, north: distance, east: 0)
                    let place = RestrictedPlace(id: kind.rawValue, kind: kind, name: nil,
                                                point: point, lines: [], outerRings: [], innerRings: [])
                    let snapshot = RestrictedPlacesSnapshot(center: user, radius: 1_500,
                                                           fetchedAt: now, places: [place])
                    let result = RestrictedPlacesPolicy.evaluate(location: user, settings: settings,
                                                                 snapshot: snapshot, now: now)
                    XCTAssertEqual(result.blocked, inside, "\(kind) latitude=\(latitude), distance=\(distance)")
                }
            }
        }
    }

    func testLongPlaygroundUsesSixtyMetreFenceInsteadOfItsCentre() {
        let user = location(60, 70)
        let ring = [(north: -30.0, east: 60.0), (30, 60), (30, 240), (-30, 240), (-30, 60)]
            .map { coordinate(from: user, north: $0.north, east: $0.east) }
        let place = RestrictedPlace(id: "elongated-playground", kind: .playground, name: nil,
                                    point: nil, lines: [], outerRings: [ring], innerRings: [])
        XCTAssertEqual(place.distance(from: user), 60, accuracy: 1)
        let snapshot = RestrictedPlacesSnapshot(center: user, radius: 1_500, fetchedAt: now, places: [place])
        let result = RestrictedPlacesPolicy.evaluate(location: user, settings: .init(enabled: true),
                                                     snapshot: snapshot, now: now)
        XCTAssertTrue(result.blocked)
        XCTAssertEqual(result.nearby.first?.distance ?? -1, 60, accuracy: 1)
    }

    func testOfflineIndexNeverMissesKnownNearbyGeometry() {
        for latitude in [43.0, 60.0, 74.0] {
            let origin = location(latitude, 70)
            var places: [RestrictedPlace] = []
            for row in -6...6 {
                for column in -6...6 {
                    let center = coordinate(from: origin, north: Double(row) * 180, east: Double(column) * 180)
                    let kind = RestrictedPlaceKind.allCases[(row + 6 + column + 6) % RestrictedPlaceKind.allCases.count]
                    let anchor = location(center.lat, center.lon)
                    let polygon = [(-25.0, -40.0), (-25, 40), (25, 40), (25, -40), (-25, -40)]
                        .map { coordinate(from: anchor, north: $0.0, east: $0.1) }
                    places.append(.init(id: "\(row)/\(column)", kind: kind, name: nil,
                                        point: nil, lines: [], outerRings: [polygon], innerRings: []))
                }
            }
            let index = RestrictedPlaceIndex(places)
            for step in -12...12 {
                let coordinate = coordinate(from: origin, north: Double(step) * 75, east: Double(step) * 53)
                let user = location(coordinate.lat, coordinate.lon)
                for radius in [70.0, 150.0, 1_000.0] {
                    let expected = Set(places.filter { $0.distance(from: user) <= radius }.map(\.id))
                    let indexed = Set(index.near(user, radius: radius).map(\.id))
                    XCTAssertTrue(expected.isSubset(of: indexed), "Index misses geometry latitude=\(latitude), step=\(step), radius=\(radius)")
                }
            }
        }
    }

    func testOfflineIndexedAndUnindexedDecisionsAgreeWhenWalkingPastTerritories() {
        let origin = location(60, 70)
        let places = (0..<12).map { number -> RestrictedPlace in
            .init(id: "fixture-\(number)", kind: RestrictedPlaceKind.allCases[number], name: nil,
                  point: coordinate(from: origin, north: Double(number) * 110, east: 0),
                  lines: [], outerRings: [], innerRings: [])
        }
        let index = RestrictedPlaceIndex(places)
        let bounds = OfflineRegionBounds(south: 59, west: 69, north: 61, east: 71)
        for step in -5...135 {
            let coordinate = coordinate(from: origin, north: Double(step) * 10, east: 0)
            let user = location(coordinate.lat, coordinate.lon)
            let brute = RestrictedPlacesSnapshot(center: origin, radius: 0, fetchedAt: now,
                                                places: places, offlineBounds: bounds)
            let indexed = RestrictedPlacesSnapshot(center: origin, radius: 0, fetchedAt: now,
                                                   places: places, offlineBounds: bounds, index: index)
            let settings = RestrictedPlaceSettings(enabled: true)
            let first = RestrictedPlacesPolicy.evaluate(location: user, settings: settings, snapshot: brute, now: now)
            let second = RestrictedPlacesPolicy.evaluate(location: user, settings: settings, snapshot: indexed, now: now)
            XCTAssertEqual(first.blocked, second.blocked, "Walk step=\(step)")
        }
    }
}
