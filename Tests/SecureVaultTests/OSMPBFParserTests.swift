import XCTest
import CoreLocation
@testable import SecureVault

/// Actual protobuf bytes exercise both PBF passes rather than mocking the
/// final places. Coordinates are synthetic and independent of any user.
final class OSMPBFParserTests: XCTestCase {
    private let table = ["", "amenity", "school", "leisure", "playground", "type", "multipolygon", "site", "outer", "inner", "education", "kindergarten"]

    private func varint(_ value: UInt64) -> Data {
        var value = value, result = Data()
        while value >= 128 { result.append(UInt8(value & 127) | 128); value >>= 7 }
        result.append(UInt8(value)); return result
    }
    private func zigzag(_ value: Int64) -> UInt64 { UInt64(bitPattern: (value &<< 1) ^ (value >> 63)) }
    private func field(_ number: Int, _ value: UInt64) -> Data { varint(UInt64(number << 3)) + varint(value) }
    private func field(_ number: Int, bytes: Data) -> Data {
        varint(UInt64(number << 3 | 2)) + varint(UInt64(bytes.count)) + bytes
    }
    private func packed(_ number: Int, _ values: [UInt64]) -> Data {
        field(number, bytes: values.reduce(into: Data()) { $0 += varint($1) })
    }
    private func node(_ id: Int64, lat: Int64, lon: Int64, keys: [UInt64] = [], values: [UInt64] = []) -> Data {
        let bytes = field(1, zigzag(id)) + packed(2, keys) + packed(3, values)
            + field(8, zigzag(lat)) + field(9, zigzag(lon))
        return field(1, bytes: bytes)
    }
    private func way(_ id: UInt64, refs: [Int64], school: Bool = false) -> Data {
        var previous: Int64 = 0
        let deltas = refs.map { ref -> UInt64 in defer { previous = ref }; return zigzag(ref - previous) }
        return field(3, bytes: field(1, id) + packed(2, school ? [1] : [])
                     + packed(3, school ? [2] : []) + packed(8, deltas))
    }
    private func relation(_ id: UInt64, members: [(ref: Int64, type: UInt64, role: UInt64)], site: Bool = false, school: Bool = true) -> Data {
        var previous: Int64 = 0
        let deltas = members.map { member -> UInt64 in defer { previous = member.ref }; return zigzag(member.ref - previous) }
        let keys: [UInt64] = school ? [1, 5] : [5]
        let values: [UInt64] = school ? [2, site ? 7 : 6] : [site ? 7 : 6]
        return field(4, bytes: field(1, id) + packed(2, keys) + packed(3, values)
                     + packed(8, members.map(\.role)) + packed(9, deltas) + packed(10, members.map(\.type)))
    }
    private func pbf(_ group: Data) -> Data {
        let strings = table.reduce(into: Data()) { $0 += field(1, bytes: Data($1.utf8)) }
        let primitive = field(1, bytes: strings) + field(2, bytes: group)
        let blob = field(1, bytes: primitive)
        let header = field(1, bytes: Data("OSMData".utf8)) + field(3, UInt64(blob.count))
        let n = UInt32(header.count)
        return Data([UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]) + header + blob
    }
    private func parse(_ bytes: Data) throws -> [RestrictedPlace] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".osm.pbf")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try OSMPBFPlaceParser.parse(url: url)
    }
    private func position(_ lat: Double, _ lon: Double) -> CLLocation {
        CLLocation(coordinate: .init(latitude: lat, longitude: lon), altitude: 0,
                   horizontalAccuracy: 1, verticalAccuracy: 1, timestamp: Date())
    }
    private var squareNodes: Data {
        node(1, lat: 0, lon: 0) + node(2, lat: 0, lon: 100_000)
        + node(3, lat: 100_000, lon: 100_000) + node(4, lat: 100_000, lon: 0)
    }

    func testWayUsesBoundaryAndBlocksInsideRatherThanPolygonCenterDistance() throws {
        let places = try parse(pbf(squareNodes + way(10, refs: [1, 2, 3, 4, 1], school: true)))
        let place = try XCTUnwrap(places.first)
        XCTAssertEqual(place.outerRings.count, 1)
        XCTAssertEqual(place.distance(from: position(0.005, 0.005)), 0)
        XCTAssertEqual(place.distance(from: position(0.005, -0.0003)), 33.4, accuracy: 1)
    }

    func testEducationOnlyNodesAndTerritorySurviveBothPBFPasses() throws {
        let schoolWay = field(3, bytes: field(1, 10) + packed(2, [10]) + packed(3, [2])
            + packed(8, [zigzag(1), zigzag(1), zigzag(1), zigzag(1), zigzag(-3)]))
        let group = squareNodes + schoolWay
            + node(5, lat: 50_000, lon: 50_000, keys: [10], values: [2])
            + node(6, lat: 60_000, lon: 60_000, keys: [10], values: [11])
        let places = try parse(pbf(group))
        XCTAssertEqual(places.count, 3)
        XCTAssertEqual(places.first { $0.id == "node/5" }?.kind, .school)
        XCTAssertEqual(places.first { $0.id == "node/6" }?.kind, .kindergarten)
        let school = try XCTUnwrap(places.first { $0.id == "way/10" })
        XCTAssertEqual(school.kind, .school)
        XCTAssertEqual(school.outerRings.count, 1)
        XCTAssertEqual(school.distance(from: position(0.005, 0.005)), 0)
    }

    func testMultipolygonWithEmptyRolesJoinsReversedFragmentsIntoTerritory() throws {
        let group = squareNodes + way(10, refs: [1, 2, 3]) + way(11, refs: [1, 4, 3])
            + relation(20, members: [(10, 1, 0), (11, 1, 0)])
        let place = try XCTUnwrap(try parse(pbf(group)).first)
        XCTAssertEqual(place.outerRings.count, 1)
        XCTAssertEqual(place.distance(from: position(0.005, 0.005)), 0)
    }

    func testSiteKeepsUntaggedMemberNodeAndBlocksAtItsLocation() throws {
        let group = node(1, lat: 50_000, lon: 50_000)
            + relation(20, members: [(1, 0, 0)], site: true)
        let place = try XCTUnwrap(try parse(pbf(group)).first)
        let current = position(0.005, 0.005)
        XCTAssertEqual(place.id, "relation/20")
        XCTAssertEqual(place.distance(from: current), 0, accuracy: 0.01)
        let snapshot = RestrictedPlacesSnapshot(center: current, radius: 1_100, fetchedAt: Date(), places: [place])
        XCTAssertTrue(RestrictedPlacesPolicy.evaluate(location: current, settings: .init(enabled: true), snapshot: snapshot).blocked)
    }

    func testNestedRelationRetainsItsUnclassifiedChildGeometry() throws {
        let group = squareNodes + way(10, refs: [1, 2, 3, 4, 1])
            + relation(20, members: [(10, 1, 8)], school: false)
            + relation(21, members: [(20, 2, 8)])
        let place = try XCTUnwrap(try parse(pbf(group)).first)
        XCTAssertEqual(place.id, "relation/21")
        XCTAssertEqual(place.distance(from: position(0.005, 0.005)), 0)
    }

    func testMissingNodeNeverCreatesAnInventedEdgeAcrossUserLocation() throws {
        let group = node(1, lat: 0, lon: -100_000) + node(2, lat: 0, lon: 100_000)
            + way(10, refs: [1, 999, 2], school: true)
        let place = try XCTUnwrap(try parse(pbf(group)).first)
        XCTAssertEqual(place.lines.count, 2)
        XCTAssertGreaterThan(place.distance(from: position(0, 0)), 1_000)
    }

    func testOpenRelationIsKeptAsKnownEdgesWithoutInventingAClosedTerritory() throws {
        let group = squareNodes + way(10, refs: [1, 2, 3, 4])
            + relation(20, members: [(10, 1, 8)])
        let place = try XCTUnwrap(try parse(pbf(group)).first)
        XCTAssertTrue(place.outerRings.isEmpty)
        XCTAssertGreaterThan(place.distance(from: position(0.005, 0.005)), 500)
    }

    func testNestedCycleCannotHangParser() throws {
        let group = node(1, lat: 0, lon: 0)
            + relation(20, members: [(21, 2, 0), (1, 0, 0)], site: true)
            + relation(21, members: [(20, 2, 0)], site: true, school: false)
        XCTAssertEqual(try parse(pbf(group)).count, 1)
    }

    func testDenseNodeDeltasAndTagsAreDecoded() throws {
        let dense = packed(1, [zigzag(1), zigzag(1)])
            + packed(8, [zigzag(100_000), zigzag(-100_000)])
            + packed(9, [zigzag(0), zigzag(0)]) + packed(10, [3, 4, 0, 3, 4, 0])
        let places = try parse(pbf(field(2, bytes: dense)))
        XCTAssertEqual(places.count, 2)
        XCTAssertEqual(try XCTUnwrap(places.first { $0.id == "node/1" }?.point).lat, 0.01, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(places.first { $0.id == "node/2" }?.point).lat, 0, accuracy: 1e-9)
    }

    func testEmptyTruncatedAndTrailingDataAreRejected() {
        XCTAssertThrowsError(try parse(Data()))
        let valid = pbf(node(1, lat: 0, lon: 0, keys: [3], values: [4]))
        XCTAssertThrowsError(try parse(Data(valid.dropLast())))
        XCTAssertThrowsError(try parse(valid + Data([0])))
    }

    func testCoordinateOverflowFailsAsErrorInsteadOfCrashing() {
        XCTAssertThrowsError(try parse(pbf(node(1, lat: .max, lon: 0, keys: [3], values: [4]))))
    }

    func testDuplicatePrimitiveIDsFailAsErrorInsteadOfCrashing() {
        let polygon = way(10, refs: [1, 2, 3, 4, 1], school: true)
        XCTAssertThrowsError(try parse(pbf(squareNodes + polygon + polygon)))
        let site = relation(20, members: [(1, 0, 0)], site: true)
        XCTAssertThrowsError(try parse(pbf(node(1, lat: 0, lon: 0) + site + site)))
    }

    func testOverflowingVarintFailsAsErrorInsteadOfCrashing() {
        let invalidNode = field(1, bytes: varint(8) + Data(repeating: 255, count: 10))
        XCTAssertThrowsError(try parse(pbf(invalidNode)))
    }
}
