import XCTest
import CoreLocation
@testable import SecureVault

final class RestrictedPlacesRadarGeometryTests: XCTestCase {
    func testPointBuffersHaveTheirConfiguredRadiusAtDifferentLatitudes() {
        for latitude in [0.0, 43, 60, 74] {
            for radius in [1.0, 65, 100, 1000] {
                let center = OSMCoordinate(lat: latitude, lon: 70)
                let circle = RestrictedPlacesRadarGeometry.circle(around: center, radius: radius)
                XCTAssertEqual(circle.count, 65)
                XCTAssertEqual(circle.first, circle.last)
                for point in circle {
                    XCTAssertTrue(point.valid)
                    let distance = CLLocation(latitude: center.lat, longitude: center.lon)
                        .distance(from: CLLocation(latitude: point.lat, longitude: point.lon))
                    XCTAssertEqual(distance, radius, accuracy: max(0.02, radius * 0.006))
                }
            }
        }
    }

    func testBufferAtDateLineDoesNotProduceInvalidLongitudes() {
        let circle = RestrictedPlacesRadarGeometry.circle(around: .init(lat: 60, lon: 179.9999), radius: 1000)
        XCTAssertTrue(circle.allSatisfy(\.valid))
        XCTAssertTrue(circle.contains { $0.lon < -179 })
        XCTAssertTrue(circle.contains { $0.lon > 179 })
    }

    func testBoundaryStrokeExtendsFullRadiusOnEachSideAndChangesWithZoom() {
        XCTAssertEqual(RestrictedPlacesRadarGeometry.bufferWidth(radius: 65, metersPerPoint: 2), 65)
        XCTAssertEqual(RestrictedPlacesRadarGeometry.bufferWidth(radius: 65, metersPerPoint: 1), 130)
        XCTAssertEqual(RestrictedPlacesRadarGeometry.bufferWidth(radius: 100, metersPerPoint: 0.5), 400)
        XCTAssertEqual(RestrictedPlacesRadarGeometry.bufferWidth(radius: 65, metersPerPoint: 0), 0)
        XCTAssertEqual(RestrictedPlacesRadarGeometry.bufferWidth(radius: .infinity, metersPerPoint: 1), 0)
    }

    func testTerritoryMarkerUsesRealBoundaryRatherThanItsSuppliedCentre() {
        let boundary = OSMCoordinate(lat: 55.002, lon: 37.002)
        let center = OSMCoordinate(lat: 55, lon: 37)
        let place = RestrictedPlace(id: "school", kind: .school, name: nil, point: center,
            lines: [], outerRings: [[boundary, .init(lat: 55.003, lon: 37.002), .init(lat: 55.003, lon: 37.003), boundary]], innerRings: [])
        XCTAssertEqual(RestrictedPlacesRadarGeometry.markerCoordinate(for: place), boundary)
        let node = RestrictedPlace(id: "police", kind: .police, name: nil, point: center, lines: [], outerRings: [], innerRings: [])
        XCTAssertEqual(RestrictedPlacesRadarGeometry.markerCoordinate(for: node), center)
        XCTAssertEqual(RestrictedPlacesRadarGeometry.isolatedPoints(for: node), [center])
        XCTAssertTrue(RestrictedPlacesRadarGeometry.isolatedPoints(for: place).isEmpty,
                      "A territory must not acquire a fictitious circle around its centre")
    }

    func testSiteRelationIsolatedNodesReceiveBuffersAlongsideTerritory() {
        let node = OSMCoordinate(lat: 55, lon: 37)
        let other = OSMCoordinate(lat: 55.002, lon: 37.002)
        let place = RestrictedPlace(id: "site", kind: .school, name: nil, point: nil,
            lines: [[node], [node], [other, .init(lat: 55.003, lon: 37.003)]],
            outerRings: [[other, .init(lat: 55.003, lon: 37.002), .init(lat: 55.003, lon: 37.003), other]], innerRings: [])
        XCTAssertEqual(RestrictedPlacesRadarGeometry.isolatedPoints(for: place), [node],
                       "A single member node needs one real circle even when the site also has a polygon")
    }
}
