import XCTest
import CoreLocation
@testable import SecureVault

// Frozen public OSM geometry sampled on 2026-10-30 via Overpass.
// Data: OpenStreetMap contributors (ODbL). Personal names/addresses omitted.
// These tests never depend on a live server being available.
final class RestrictedPlacesRealGeometryTests: XCTestCase {
    func testMappedTerritoryBoundariesBlockOnlineAndOfflineForPriorityTypes() throws {
        let fixtures: [(String, RestrictedPlaceKind, String)] = [
        ("moscow", .school, #"{"elements":[{"type":"way","id":296899004,"bounds":{"minlat":55.7485129,"minlon":37.6502441,"maxlat":55.7492182,"maxlon":37.6518655},"geometry":[{"lat":55.7489711,"lon":37.6518655},{"lat":55.7488737,"lon":37.6517391},{"lat":55.7486684,"lon":37.6516666},{"lat":55.748682,"lon":37.6515003},{"lat":55.7486291,"lon":37.6512831},{"lat":55.7485385,"lon":37.6512241},{"lat":55.7485129,"lon":37.6507279},{"lat":55.7485449,"lon":37.6502441},{"lat":55.7491382,"lon":37.6505026},{"lat":55.7492182,"lon":37.6518186},{"lat":55.7489711,"lon":37.6518655}],"tags":{"amenity":"school"}}]}"#),
        ("moscow", .kindergarten, #"{"elements":[{"type":"way","id":48303492,"bounds":{"minlat":55.7361645,"minlon":37.6433708,"maxlat":55.7364142,"maxlon":37.6440333},"geometry":[{"lat":55.7361645,"lon":37.6434464},{"lat":55.7363179,"lon":37.6433708},{"lat":55.7363371,"lon":37.6434934},{"lat":55.736286,"lon":37.6435186},{"lat":55.7363401,"lon":37.6438652},{"lat":55.7363958,"lon":37.6438377},{"lat":55.7364142,"lon":37.6439554},{"lat":55.7362563,"lon":37.6440333},{"lat":55.7361645,"lon":37.6434464}],"tags":{"amenity":"kindergarten"}}]}"#),
        ("moscow", .playground, #"{"elements":[{"type":"way","id":142394260,"bounds":{"minlat":55.735461,"minlon":37.6390682,"maxlat":55.7357477,"maxlon":37.6394003},"geometry":[{"lat":55.735461,"lon":37.6392302},{"lat":55.7354949,"lon":37.6394003},{"lat":55.7357477,"lon":37.6392412},{"lat":55.7357415,"lon":37.6390682},{"lat":55.735461,"lon":37.6392302}],"tags":{"leisure":"playground"}}]}"#),
        ("moscow", .police, #"{"elements":[{"type":"node","id":5095038366,"lat":55.7424417,"lon":37.6530483,"tags":{"amenity":"police"}}]}"#),
        ("minsk", .school, #"{"elements":[{"type":"way","id":338891292,"bounds":{"minlat":53.9055819,"minlon":27.5483606,"maxlat":53.9068526,"maxlon":27.5507577},"geometry":[{"lat":53.9063121,"lon":27.5483606},{"lat":53.9064423,"lon":27.5487228},{"lat":53.9066555,"lon":27.5492172},{"lat":53.9066696,"lon":27.5492499},{"lat":53.9067541,"lon":27.5492819},{"lat":53.9068526,"lon":27.5497958},{"lat":53.9067728,"lon":27.5498898},{"lat":53.9061538,"lon":27.5506189},{"lat":53.9060359,"lon":27.5507577},{"lat":53.9059154,"lon":27.5503786},{"lat":53.9055819,"lon":27.5493293},{"lat":53.9056279,"lon":27.5490932},{"lat":53.9063121,"lon":27.5483606}],"tags":{"amenity":"school"}}]}"#),
        ("minsk", .kindergarten, #"{"elements":[{"type":"way","id":336559335,"bounds":{"minlat":53.9005726,"minlon":27.5557013,"maxlat":53.9013635,"maxlon":27.5573727},"geometry":[{"lat":53.9013635,"lon":27.5568238},{"lat":53.9009544,"lon":27.5573727},{"lat":53.9005726,"lon":27.5565529},{"lat":53.9006599,"lon":27.5564304},{"lat":53.9006056,"lon":27.5562782},{"lat":53.9005994,"lon":27.5562003},{"lat":53.9006202,"lon":27.5561473},{"lat":53.9006995,"lon":27.5560446},{"lat":53.9006682,"lon":27.5559526},{"lat":53.9008997,"lon":27.5557013},{"lat":53.9009852,"lon":27.5559526},{"lat":53.901132,"lon":27.5562906},{"lat":53.9013635,"lon":27.5568238}],"tags":{"amenity":"kindergarten"}}]}"#),
        ("minsk", .playground, #"{"elements":[{"type":"way","id":243332420,"bounds":{"minlat":53.904903,"minlon":27.5637245,"maxlat":53.9052079,"maxlon":27.5642154},"geometry":[{"lat":53.9052079,"lon":27.5638854},{"lat":53.9049804,"lon":27.5642154},{"lat":53.904903,"lon":27.5640517},{"lat":53.9051273,"lon":27.5637245},{"lat":53.9052079,"lon":27.5638854}],"tags":{"leisure":"playground"}}]}"#),
        ("minsk", .police, #"{"elements":[{"type":"way","id":960462884,"bounds":{"minlat":53.8995115,"minlon":27.5482387,"maxlat":53.9000361,"maxlon":27.5492365},"geometry":[{"lat":53.8997192,"lon":27.5491411},{"lat":53.8997162,"lon":27.5491709},{"lat":53.899713,"lon":27.5492208},{"lat":53.8997639,"lon":27.5492282},{"lat":53.8998209,"lon":27.5492365},{"lat":53.8998801,"lon":27.5491548},{"lat":53.8998955,"lon":27.5488997},{"lat":53.9000154,"lon":27.5487561},{"lat":53.9000361,"lon":27.5485303},{"lat":53.8999125,"lon":27.5482494},{"lat":53.8998809,"lon":27.5482387},{"lat":53.8998081,"lon":27.5483331},{"lat":53.8997703,"lon":27.5483821},{"lat":53.8997529,"lon":27.5486274},{"lat":53.8997512,"lon":27.5486513},{"lat":53.8996339,"lon":27.5486375},{"lat":53.8995975,"lon":27.5489806},{"lat":53.8995115,"lon":27.5491044},{"lat":53.8996454,"lon":27.5491258},{"lat":53.8997192,"lon":27.5491411}],"tags":{"amenity":"police"}}]}"#),
        ("almaty", .school, #"{"elements":[{"type":"way","id":51008119,"bounds":{"minlat":43.2479528,"minlon":76.9372785,"maxlat":43.2488824,"maxlon":76.9380566},"geometry":[{"lat":43.2479528,"lon":76.9373748},{"lat":43.2488384,"lon":76.9372785},{"lat":43.2488824,"lon":76.9380422},{"lat":43.2487496,"lon":76.9380566},{"lat":43.2487135,"lon":76.9374302},{"lat":43.2484147,"lon":76.9374627},{"lat":43.2484197,"lon":76.9375505},{"lat":43.2479658,"lon":76.9375998},{"lat":43.2479528,"lon":76.9373748}],"tags":{"amenity":"school"}}]}"#),
        ("almaty", .kindergarten, #"{"elements":[{"type":"way","id":50876658,"bounds":{"minlat":43.2538398,"minlon":76.9215883,"maxlat":43.2542075,"maxlon":76.9217816},"geometry":[{"lat":43.2541978,"lon":76.9215883},{"lat":43.2542075,"lon":76.9217379},{"lat":43.2538495,"lon":76.9217816},{"lat":43.2538398,"lon":76.921632},{"lat":43.2541978,"lon":76.9215883}],"tags":{"amenity":"kindergarten"}}]}"#),
        ("almaty", .playground, #"{"elements":[{"type":"way","id":1123262730,"bounds":{"minlat":43.2487027,"minlon":76.9305303,"maxlat":43.2488171,"maxlon":76.9309582},"geometry":[{"lat":43.2488171,"lon":76.9305862},{"lat":43.2487027,"lon":76.9305303},{"lat":43.2487379,"lon":76.9309574},{"lat":43.2488125,"lon":76.9309582},{"lat":43.2487983,"lon":76.9306409},{"lat":43.2488171,"lon":76.9305862}],"tags":{"leisure":"playground"}}]}"#),
        ("almaty", .police, #"{"elements":[{"type":"node","id":2968160392,"lat":43.2503259,"lon":76.9247474,"tags":{"amenity":"police"}}]}"#)
        ]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for (city, expectedKind, json) in fixtures {
            let places = try RestrictedPlacesParser.parse(Data(json.utf8))
            XCTAssertEqual(places.count, 1, city)
            let place = try XCTUnwrap(places.first)
            XCTAssertEqual(place.kind, expectedKind, "\(city) \(place.id)")
            let boundary = try XCTUnwrap(place.point ?? place.outerRings.first?.first ?? place.lines.first?.first)
            let user = CLLocation(coordinate: boundary.coordinate, altitude: 0,
                horizontalAccuracy: 1, verticalAccuracy: 1, timestamp: now)
            XCTAssertEqual(place.distance(from: user), 0, accuracy: 0.1, "\(city) \(place.id)")
            let bounds = OfflineRegionBounds(south: boundary.lat - 0.1, west: boundary.lon - 0.1,
                                             north: boundary.lat + 0.1, east: boundary.lon + 0.1)
            let online = RestrictedPlacesSnapshot(center: user, radius: 1_500,
                                                   fetchedAt: now, places: places)
            let offline = RestrictedPlacesSnapshot(center: user, radius: 0, fetchedAt: now,
                places: places, offlineBounds: bounds, index: RestrictedPlaceIndex(places))
            for snapshot in [online, offline] {
                let result = RestrictedPlacesPolicy.evaluate(location: user, settings: .init(enabled: true),
                    snapshot: snapshot, now: now)
                XCTAssertTrue(result.blocked, "Boundary of \(city) \(place.id) must be protected")
                XCTAssertEqual(result.nearby.first?.kind, expectedKind)
            }
        }
    }
}
