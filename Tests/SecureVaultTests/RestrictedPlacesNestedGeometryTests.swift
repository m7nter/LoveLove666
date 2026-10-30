import XCTest
import CoreLocation
@testable import SecureVault

final class RestrictedPlacesNestedGeometryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let kinds: [(RestrictedPlaceKind, [String: String])] = [
        (.playground, ["leisure": "playground"]),
        (.kindergarten, ["amenity": "kindergarten"]),
        (.school, ["amenity": "school"]),
        (.police, ["amenity": "police"])
    ]

    private func coordinate(north: Double, east: Double) -> OSMCoordinate {
        let radians = Double.pi / 180
        return .init(lat: 55 + north / 6_371_000 / radians,
                     lon: 70 + east / (6_371_000 * cos(55 * radians)) / radians)
    }

    private func location(north: Double = 0, east: Double = 0) -> CLLocation {
        let point = coordinate(north: north, east: east)
        return CLLocation(coordinate: point.coordinate, altitude: 0,
                          horizontalAccuracy: 1, verticalAccuracy: 1, timestamp: now)
    }

    private func ring(_ halfSize: Double, east: Double = 0) -> [OSMCoordinate] {
        [(-halfSize, -halfSize), (-halfSize, halfSize), (halfSize, halfSize),
         (halfSize, -halfSize), (-halfSize, -halfSize)]
            .map { coordinate(north: $0.0, east: east + $0.1) }
    }

    private func wayMember(_ ring: [OSMCoordinate], role: String) -> [String: Any] {
        ["type": "way", "ref": 1, "role": role,
         "geometry": ring.map { ["lat": $0.lat, "lon": $0.lon] }]
    }

    private func parse(tags: [String: String], members: [[String: Any]]) throws -> RestrictedPlace {
        var tags = tags
        tags["type"] = "multipolygon"
        let element: [String: Any] = ["type": "relation", "id": 1, "tags": tags, "members": members]
        let data = try JSONSerialization.data(withJSONObject: ["elements": [element]])
        return try XCTUnwrap(RestrictedPlacesParser.parse(data).first)
    }

    func testOuterIslandInsideCourtyardRemainsProtectedForAllPriorityCategories() throws {
        // The OSM multipolygon model explicitly permits an outer island within
        // an inner hole. A 500m-wide island cannot be treated as a clear area
        // merely because the surrounding courtyard also contains the user.
        for (kind, tags) in kinds {
            let place = try parse(tags: tags, members: [
                wayMember(ring(1_000), role: "outer"),
                wayMember(ring(600).reversed().map { $0 }, role: "inner"),
                wayMember(ring(250), role: "outer")
            ])
            XCTAssertEqual(place.kind, kind)
            XCTAssertEqual(place.distance(from: location()), 0, "Inside outer island: \(kind)")
            XCTAssertGreaterThan(place.distance(from: location(north: 400)), 100,
                                 "Courtyard outside the island stays clear: \(kind)")
            XCTAssertEqual(place.distance(from: location(north: 800)), 0,
                           "Main outer territory stays protected: \(kind)")

            let online = RestrictedPlacesSnapshot(center: location(), radius: 4_000,
                                                  fetchedAt: now, places: [place])
            let offline = RestrictedPlacesSnapshot(center: location(), radius: 0,
                fetchedAt: now, places: [place],
                offlineBounds: .init(south: 54.9, west: 69.9, north: 55.1, east: 70.1),
                index: RestrictedPlaceIndex([place]))
            for snapshot in [online, offline] {
                let settings = RestrictedPlaceSettings(enabled: true)
                XCTAssertTrue(RestrictedPlacesPolicy.evaluate(location: location(), settings: settings,
                    snapshot: snapshot, now: now).blocked, "Island must block: \(kind)")
                XCTAssertFalse(RestrictedPlacesPolicy.evaluate(location: location(north: 400), settings: settings,
                    snapshot: snapshot, now: now).blocked, "Courtyard must remain clear: \(kind)")
            }
        }
    }

    func testHoleInsideOuterIslandStaysAHoleAndDisjointOuterStaysProtected() {
        let place = RestrictedPlace(id: "nested-school", kind: .school, name: nil,
            point: nil, lines: [], outerRings: [ring(1_000), ring(350), ring(200, east: 2_000)],
            innerRings: [ring(600), ring(150)])
        XCTAssertGreaterThan(place.distance(from: location()), 100)
        XCTAssertEqual(place.distance(from: location(north: 250)), 0)
        XCTAssertGreaterThan(place.distance(from: location(north: 500)), 0)
        XCTAssertEqual(place.distance(from: location(north: 800)), 0)
        XCTAssertEqual(place.distance(from: location(east: 2_000)), 0)
    }

    func testUnresolvedNestedBoundaryCannotBeSilentlyDiscardedFromOnlineRelation() {
        for (_, tags) in kinds {
            for role in ["", "outer", "inner"] {
                let nested: [String: Any] = ["type": "relation", "ref": 2, "role": role]
                XCTAssertThrowsError(try parse(tags: tags, members: [
                    wayMember(ring(1_000), role: "outer"), nested
                ]), "Unresolved \(role) relation must not produce a verified partial territory")
            }
        }
    }

    func testNonBoundaryRelationMemberDoesNotInvalidateCompleteDirectBoundary() throws {
        let place = try parse(tags: ["amenity": "school"], members: [
            wayMember(ring(200), role: "outer"),
            ["type": "relation", "ref": 2, "role": "label"]
        ])
        XCTAssertEqual(place.distance(from: location()), 0)
    }
}
