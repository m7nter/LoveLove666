import XCTest
import CoreLocation
@testable import SecureVault

/// Live reported OSM geometries translated to synthetic coordinates. Names,
/// IDs and user-region coordinates are deliberately absent from these fixtures.
final class ReportedOSMRegressionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func user() -> CLLocation {
        .init(coordinate: .init(latitude: 0, longitude: 0), altitude: 0,
              horizontalAccuracy: 1, verticalAccuracy: 1, timestamp: now)
    }

    func testAllReportedPlaygroundsSurviveParserAndIndexAndRadarUses500Metres() throws {
        let places = try RestrictedPlacesParser.parse(Data(Self.playgrounds.utf8))
        XCTAssertEqual(places.count, 8)
        XCTAssertTrue(places.allSatisfy { $0.kind == .playground })
        let settings = RestrictedPlaceSettings(enabled: true)
        let index = RestrictedPlaceIndex(places)
        XCTAssertEqual(Set(index.near(user(), radius: 1_000).map(\.id)), Set(places.map(\.id)))
        let online = RestrictedPlacesSnapshot(center: user(), radius: 1_100, fetchedAt: now, places: places)
        let offline = RestrictedPlacesSnapshot(center: user(), radius: 0, fetchedAt: now, places: places,
            offlineBounds: .init(south: -0.1, west: -0.1, north: 0.1, east: 0.1), index: index)
        for snapshot in [online, offline] {
            let visible = try XCTUnwrap(RestrictedPlacesRadarPolicy.places(location: user(),
                settings: settings, snapshot: snapshot, now: now))
            XCTAssertEqual(visible.map(\.id), ["way/2"], "Only this reported footprint is within the new 500 m overview")
        }
    }

    func testReportedCollegeTaggedLyceumKeepsBothOuterBoundaryAndCourtyard() throws {
        let places = try RestrictedPlacesParser.parse(Data(Self.lyceum.utf8))
        let school = try XCTUnwrap(places.first)
        XCTAssertEqual(places.count, 1)
        XCTAssertEqual(school.kind, .school)
        XCTAssertEqual(school.outerRings.count, 1)
        XCTAssertEqual(school.innerRings.count, 1)
        let settings = RestrictedPlaceSettings(enabled: true)
        let snapshot = RestrictedPlacesSnapshot(center: user(), radius: 1_100, fetchedAt: now, places: places)
        XCTAssertTrue(RestrictedPlacesPolicy.evaluate(location: user(), settings: settings,
            snapshot: snapshot, now: now).blocked)
        XCTAssertEqual(RestrictedPlacesRadarPolicy.places(location: user(), settings: settings,
            snapshot: snapshot, now: now)?.map(\.kind), [.school])
    }

    private static let playgrounds = #"{"elements":[{"type":"way","id":1,"tags":{"leisure":"playground"},"geometry":[{"lat":-0.0028801,"lon":-0.004575391},{"lat":-0.0030731,"lon":-0.004567058},{"lat":-0.0030782,"lon":-0.00468465},{"lat":-0.0028852,"lon":-0.00469293},{"lat":-0.0028801,"lon":-0.004575391}]},{"type":"way","id":2,"tags":{"leisure":"playground"},"geometry":[{"lat":-0.0005324,"lon":-0.003339587},{"lat":-0.0007487,"lon":-0.003337348},{"lat":-0.0009539,"lon":-0.003329588},{"lat":-0.0011653,"lon":-0.003494674},{"lat":-0.0011646,"lon":-0.003718296},{"lat":-0.000569,"lon":-0.003684706},{"lat":-0.0005324,"lon":-0.003339587}]},{"type":"way","id":3,"tags":{"leisure":"playground"},"geometry":[{"lat":-0.0074634,"lon":-0.004871192},{"lat":-0.0074503,"lon":-0.004681473},{"lat":-0.0079253,"lon":-0.004664756},{"lat":-0.0079309,"lon":-0.004854683},{"lat":-0.0074634,"lon":-0.004871192}]},{"type":"way","id":4,"tags":{"leisure":"playground"},"geometry":[{"lat":-0.0050373,"lon":0.000866052},{"lat":-0.0048901,"lon":0.000867094},{"lat":-0.0048817,"lon":0.000967656},{"lat":-0.0050278,"lon":0.000982498},{"lat":-0.0050373,"lon":0.000866052}]},{"type":"way","id":5,"tags":{"leisure":"playground"},"geometry":[{"lat":-0.0076095,"lon":0.001730646},{"lat":-0.0075904,"lon":0.001847092},{"lat":-0.0077853,"lon":0.001904273},{"lat":-0.0078191,"lon":0.001760278},{"lat":-0.0076095,"lon":0.001730646}]},{"type":"way","id":6,"tags":{"leisure":"playground"},"geometry":[{"lat":-0.0018908,"lon":-0.007600637},{"lat":-0.0020232,"lon":-0.007592981},{"lat":-0.0020105,"lon":-0.007363839},{"lat":-0.0018781,"lon":-0.007371495},{"lat":-0.0018908,"lon":-0.007600637}]},{"type":"way","id":7,"tags":{"leisure":"playground"},"geometry":[{"lat":-0.001654,"lon":-0.008659689},{"lat":-0.001817,"lon":-0.008652033},{"lat":-0.0018195,"lon":-0.008555325},{"lat":-0.0016489,"lon":-0.008568032},{"lat":-0.001654,"lon":-0.008659689}]},{"type":"way","id":8,"tags":{"leisure":"playground"},"geometry":[{"lat":0.0037713,"lon":0.007727498},{"lat":0.0038111,"lon":0.008027257},{"lat":0.0036463,"lon":0.008049182},{"lat":0.0036065,"lon":0.007749371},{"lat":0.0037713,"lon":0.007727498}]}]}"#
    private static let lyceum = #"{"elements":[{"type":"relation","id":1,"tags":{"type":"multipolygon","building":"yes","amenity":"college","name":"Физико-математический лицей (учебный корпус №2)"},"members":[{"type":"way","ref":100,"role":"inner","geometry":[{"lat":1.69e-05,"lon":0.000229324},{"lat":-0.0001324,"lon":0.000264584},{"lat":-9.2e-05,"lon":0.000435835},{"lat":5.73e-05,"lon":0.000400626},{"lat":1.69e-05,"lon":0.000229324}]},{"type":"way","ref":101,"role":"outer","geometry":[{"lat":2.31e-05,"lon":2.3021e-05},{"lat":0.0001977,"lon":-2.1563e-05},{"lat":0.0001816,"lon":-8.474e-05},{"lat":0.0001508,"lon":-7.6875e-05},{"lat":0.0001377,"lon":-0.000128021},{"lat":-3.27e-05,"lon":-8.4479e-05},{"lat":-2.81e-05,"lon":-6.6511e-05},{"lat":-0.000109,"lon":-4.5833e-05},{"lat":-7.95e-05,"lon":6.9584e-05},{"lat":-1.05e-05,"lon":5.1979e-05},{"lat":1.04e-05,"lon":0.00013375},{"lat":-0.0002536,"lon":0.000201199},{"lat":-0.0001486,"lon":0.000612242},{"lat":5.43e-05,"lon":0.000560419},{"lat":5.86e-05,"lon":0.000577346},{"lat":0.000239,"lon":0.000531252},{"lat":0.0001978,"lon":0.000370158},{"lat":0.0001781,"lon":0.000375158},{"lat":0.0001107,"lon":0.000111355},{"lat":4.97e-05,"lon":0.00012698},{"lat":2.31e-05,"lon":2.3021e-05}]}]}]}"#
}
