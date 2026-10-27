import XCTest
import CoreLocation
@testable import SecureVault

final class RestrictedPlacesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func location(_ latitude: Double = 0, _ longitude: Double = 0, accuracy: Double = 5, age: Double = 0) -> CLLocation {
        CLLocation(coordinate: .init(latitude: latitude, longitude: longitude), altitude: 0,
                   horizontalAccuracy: accuracy, verticalAccuracy: 1, timestamp: now.addingTimeInterval(-age))
    }
    private var enabled: RestrictedPlaceSettings { var s = RestrictedPlaceSettings(); s.enabled = true; return s }
    private func point(_ latitude: Double = 0, _ longitude: Double = 0, kind: RestrictedPlaceKind = .playground) -> RestrictedPlace {
        .init(id: "node/1", kind: kind, name: nil, point: .init(lat: latitude, lon: longitude), lines: [], outerRings: [], innerRings: [])
    }
    private func snapshot(_ places: [RestrictedPlace], age: Double = 0, radius: Double = 1100) -> RestrictedPlacesSnapshot {
        .init(center: location(), radius: radius, fetchedAt: now.addingTimeInterval(-age), places: places)
    }
    private func decision(_ location: CLLocation?, _ places: [RestrictedPlace] = [], settings: RestrictedPlaceSettings? = nil) -> CaptureZoneDecision {
        RestrictedPlacesPolicy.evaluate(location: location, settings: settings ?? enabled, snapshot: snapshot(places), now: now)
    }
    private func decisionAt(_ current: CLLocation, _ places: [RestrictedPlace], settings: RestrictedPlaceSettings? = nil) -> CaptureZoneDecision {
        let nearby = RestrictedPlacesSnapshot(center: current, radius: 2_000,
                                              fetchedAt: now, places: places)
        return RestrictedPlacesPolicy.evaluate(location: current, settings: settings ?? enabled,
                                               snapshot: nearby, now: now)
    }
    private func offset(_ location: CLLocation, northMeters: Double) -> CLLocation {
        let latitude = location.coordinate.latitude + northMeters / 111_132.0
        return CLLocation(coordinate: .init(latitude: latitude, longitude: location.coordinate.longitude),
                          altitude: 0, horizontalAccuracy: 1, verticalAccuracy: 1, timestamp: now)
    }
    private func parse(_ json: String) throws -> [RestrictedPlace] { try RestrictedPlacesParser.parse(Data(json.utf8)) }

    func testDisabledAllowsWithoutGPSOrNetwork() {
        XCTAssertFalse(RestrictedPlacesPolicy.evaluate(location: nil, settings: .init(), snapshot: nil, now: now).blocked)
    }
    func testAccuracyAtFifteenAndWorseIsBlocked() {
        XCTAssertFalse(decision(location(accuracy: 14.99)).blocked)
        XCTAssertTrue(decision(location(accuracy: 15)).blocked)
        XCTAssertTrue(decision(location(accuracy: 30)).message.contains("GPS"))
        XCTAssertTrue(decision(location(accuracy: -1)).blocked)
    }
    func testAccuracyThresholdIsConfigurable() {
        var settings = enabled; settings.maximumAccuracy = 10
        XCTAssertTrue(decision(location(accuracy: 10), settings: settings).blocked)
        XCTAssertFalse(decision(location(accuracy: 9), settings: settings).blocked)
    }
    func testMissingStaleFutureAndInvalidGPSAreBlocked() {
        XCTAssertTrue(decision(nil).blocked)
        XCTAssertTrue(decision(location(age: 16)).blocked)
        XCTAssertTrue(decision(location(age: -16)).blocked)
        XCTAssertTrue(decision(location(100, 0)).blocked)
    }
    func testMissingExpiredAndOutOfCoverageDataBlock() {
        XCTAssertTrue(RestrictedPlacesPolicy.evaluate(location: location(), settings: enabled, snapshot: nil, now: now).blocked)
        XCTAssertTrue(RestrictedPlacesPolicy.evaluate(location: location(), settings: enabled, snapshot: snapshot([], age: 600), now: now).blocked)
        XCTAssertTrue(RestrictedPlacesPolicy.evaluate(location: location(0.02), settings: enabled, snapshot: snapshot([]), now: now).blocked)
    }
    func testSuccessfulEmptyResponseAllowsCapture() { XCTAssertFalse(decision(location()).blocked) }
    func testFilteredOnlineCacheCannotVerifyNewlyEnabledCategory() {
        var settings = enabled
        settings.disabledKinds = Set(RestrictedPlaceKind.allCases.filter { $0 != .school })
        let cached = RestrictedPlacesSnapshot(center: location(), radius: 1_100,
                                              fetchedAt: now, places: [], queriedKinds: [.school])
        XCTAssertFalse(RestrictedPlacesPolicy.evaluate(location: location(), settings: settings,
                                                       snapshot: cached, now: now).blocked)
        settings.disabledKinds.remove(.playground)
        XCTAssertTrue(RestrictedPlacesPolicy.evaluate(location: location(), settings: settings,
                                                      snapshot: cached, now: now).blocked)
    }
    func testEmptyLegacyGeometryDoesNotCrashDistanceEvaluation() {
        let malformed = RestrictedPlace(id: "empty", kind: .playground, name: nil,
                                        point: nil, lines: [[]], outerRings: [], innerRings: [])
        XCTAssertEqual(malformed.distance(from: location()), .infinity)
    }
    func testEmptyOnlineResponseCanBeConfiguredToBlockCapture() {
        var settings = enabled
        settings.blockOnEmptyOnlineResponse = true
        let empty = RestrictedPlacesSnapshot(center: location(), radius: 1_100, fetchedAt: now,
                                              places: [], isEmptyOnlineResponse: true)
        let result = RestrictedPlacesPolicy.evaluate(location: location(), settings: settings,
                                                     snapshot: empty, now: now)
        XCTAssertTrue(result.blocked)
        XCTAssertTrue(result.message.contains("пустой ответ"))
    }
    func testPointRadiusIncludesGPSUncertainty() {
        let place = point(0.00060)
        let distance = place.distance(from: location())
        XCTAssertGreaterThan(distance, 65); XCTAssertLessThan(distance, 70)
        let result = decision(location(), [place])
        XCTAssertTrue(result.blocked); XCTAssertTrue(result.message.contains("погрешности"))
        XCTAssertFalse(decision(location(0, 0, accuracy: 1), [place]).blocked)
    }
    func testCustomDistanceAndCategoryToggleAreApplied() {
        let place = point(0.001, kind: .police)
        XCTAssertFalse(decision(location(), [place]).blocked)
        var settings = enabled; settings.radii[RestrictedPlaceKind.police.rawValue] = 150
        XCTAssertTrue(decision(location(), [place], settings: settings).blocked)
        settings.disabledKinds.insert(.police)
        XCTAssertFalse(decision(location(), [place], settings: settings).blocked)
    }
    func testNoSelectedTypesCannotSilentlyDisableControl() {
        var settings = enabled; settings.disabledKinds = Set(RestrictedPlaceKind.allCases)
        XCTAssertTrue(decision(location(), settings: settings).blocked)
    }
    func testDistanceToTerritoryEdgeAndInsideTerritory() throws {
        let places = try parse("""
        {"elements":[{"type":"way","id":1,"tags":{"amenity":"kindergarten"},"geometry":[
        {"lat":0,"lon":0},{"lat":0,"lon":0.01},{"lat":0.01,"lon":0.01},{"lat":0.01,"lon":0},{"lat":0,"lon":0}]}]}
        """)
        let place = try XCTUnwrap(places.first)
        XCTAssertEqual(place.distance(from: location(0.005, 0.005)), 0)
        XCTAssertEqual(place.distance(from: location(0.005, -0.0003)), 33.4, accuracy: 1)
        XCTAssertEqual(place.distance(from: location(0, 0)), 0, accuracy: 0.1)
    }
    func testSplitMultipolygonAndCourtyardHole() throws {
        let places = try parse("""
        {"elements":[{"type":"relation","id":2,"tags":{"amenity":"school","type":"multipolygon"},"members":[
        {"type":"way","role":"outer","geometry":[{"lat":0,"lon":0},{"lat":0,"lon":0.01},{"lat":0.01,"lon":0.01}]},
        {"type":"way","role":"outer","geometry":[{"lat":0,"lon":0},{"lat":0.01,"lon":0},{"lat":0.01,"lon":0.01}]},
        {"type":"way","role":"inner","geometry":[{"lat":0.004,"lon":0.004},{"lat":0.004,"lon":0.006},{"lat":0.006,"lon":0.006},{"lat":0.006,"lon":0.004},{"lat":0.004,"lon":0.004}]}]}]}
        """)
        let place = try XCTUnwrap(places.first)
        XCTAssertEqual(place.outerRings.count, 1)
        XCTAssertEqual(place.distance(from: location(0.002, 0.002)), 0)
        XCTAssertGreaterThan(place.distance(from: location(0.005, 0.005)), 100)
    }
    func testPartialResponseAndBrokenGeometryFailClosed() {
        XCTAssertThrowsError(try parse("{\"remark\":\"runtime error: timeout\",\"elements\":[]}"))
        XCTAssertThrowsError(try parse("{\"elements\":[{\"type\":\"way\",\"id\":1,\"tags\":{\"amenity\":\"school\"}}]}"))
        XCTAssertThrowsError(try parse("{\"elements\":[{\"type\":\"node\",\"id\":1,\"lat\":100,\"lon\":0,\"tags\":{\"amenity\":\"school\"}}]}"))
        XCTAssertThrowsError(try RestrictedPlacesParser.joinRings([[.init(lat: 0, lon: 0), .init(lat: 1, lon: 1)]]))
    }
    func testMixedResponseCannotSilentlyDiscardMalformedNearbyObject() {
        XCTAssertThrowsError(try parse("""
        {"elements":[
          {"type":"node","id":1,"lat":0.005,"lon":0,"tags":{"amenity":"school"}},
          {"type":"way","id":2,"tags":{"leisure":"playground"}}
        ]}
        """))
    }
    func testSiteRelationUsesMemberGeometryWithoutInventingAPerimeter() throws {
        let places = try parse("""
        {"elements":[{"type":"relation","id":3,"tags":{"amenity":"school","type":"site"},"members":[
        {"type":"node","role":"entrance","lat":0,"lon":0},
        {"type":"way","role":"building","geometry":[{"lat":0,"lon":0},{"lat":0,"lon":0.001},{"lat":0.001,"lon":0.001},{"lat":0.001,"lon":0},{"lat":0,"lon":0}]}]}]}
        """)
        let place = try XCTUnwrap(places.first)
        XCTAssertEqual(place.distance(from: location(0.0005, 0.0005)), 0)
        XCTAssertGreaterThan(place.distance(from: location(0.005, 0.005)), 500)
    }
    func testCategoriesAndSpecificServicePriority() {
        XCTAssertEqual(RestrictedPlaceKind.classify(["office":"government","name":"УФСБ России"]), .security)
        XCTAssertEqual(RestrictedPlaceKind.classify(["office":"government","name":"Федеральная служба безопасности"]), .security)
        XCTAssertEqual(RestrictedPlaceKind.classify(["office":"government","name":"Министерство внутренних дел"]), .police)
        XCTAssertEqual(RestrictedPlaceKind.classify(["amenity":"police","name":"Управление МВД"]), .police)
        XCTAssertEqual(RestrictedPlaceKind.classify(["government":"recruitment"]), .recruitment)
        XCTAssertEqual(RestrictedPlaceKind.classify(["government":"prosecutor"]), .prosecutor)
        XCTAssertEqual(RestrictedPlaceKind.classify(["amenity":"courthouse"]), .court)
        XCTAssertEqual(RestrictedPlaceKind.classify(["amenity":"townhall"]), .administration)
        XCTAssertEqual(RestrictedPlaceKind.classify(["landuse":"military"]), .military)
        XCTAssertEqual(RestrictedPlaceKind.classify(["office":"government","government":"tax"]), .government)
        XCTAssertEqual(RestrictedPlaceKind.classify(["leisure":"pitch"]), .sports)
        XCTAssertEqual(RestrictedPlaceKind.classify(["playground":"slide"]), .playground)
        XCTAssertEqual(RestrictedPlaceKind.classify(["name":"Детская площадка во дворе"]), .playground)
        XCTAssertNil(RestrictedPlaceKind.classify(["amenity":"cafe"]))
    }

    func testOnlineQueryRequestsNameKeysAndLeavesUnicodeClassificationLocal() {
        let fixtures: [(String, String, RestrictedPlaceKind)] = [
            ("name:ru", "Детская площадка", .playground),
            ("official_name", "УФСБ России", .security),
            ("operator", "Министерство внутренних дел", .police),
            ("operator:ru", "Прокуратура", .prosecutor),
            ("name", "Военный комиссариат", .recruitment)
        ]
        let query = RestrictedPlacesMonitor.query(near: location(), radius: 1_100)
        for (key, value, kind) in fixtures {
            XCTAssertEqual(RestrictedPlaceKind.classify(["building": "yes", key: value]), kind)
            XCTAssertTrue(query.contains(key), "Online query must search \(key)")
        }
        XCTAssertFalse(query.contains("фсб"))
        XCTAssertFalse(query.contains("детск"))
        XCTAssertTrue(query.contains("[\"name:ru\"]"))
    }
    func testDefaultDistancesPersistenceAndReset() throws {
        XCTAssertEqual(enabled.radius(for: .school), 65)
        XCTAssertEqual(enabled.radius(for: .security), 100)
        let store = SettingsStore.shared, previous = store.restrictedPlaces
        defer { store.restrictedPlaces = previous }
        var settings = enabled; settings.disabledKinds = [.school]; settings.radii["police"] = 250
        store.restrictedPlaces = settings
        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: "restrictedPlaces"))
        XCTAssertEqual(try JSONDecoder().decode(RestrictedPlaceSettings.self, from: data), settings)
        store.resetToFactory()
        XCTAssertFalse(store.restrictedPlaces.enabled)
        XCTAssertEqual(store.restrictedPlaces.radius(for: .police), 100)
    }
    func testQueryMatchesDesktopBoundedGeometryRequest() {
        let query = RestrictedPlacesMonitor.query(near: location(55.75, 37.62), radius: 1100)
        XCTAssertTrue(query.contains("around:1100,55.7500000,37.6200000"))
        XCTAssertFalse(query.contains("is_in("))
        XCTAssertFalse(query.contains("pivot.enclosing"))
        XCTAssertTrue(query.contains("out tags geom"))
        XCTAssertFalse(query.contains("out center"))
        XCTAssertTrue(query.contains("[playground]"))
        XCTAssertFalse(query.contains("[^"), "Overpass must accept the name filter on Cyrillic-capable mirrors")
        XCTAssertTrue(query.contains("фсб"))
    }

    func testSafetyChecksNeverUseRegionalOnlyOverpassMirror() {
        let hosts = OverpassConfiguration.worldwideEndpoints.compactMap(\.host)
        XCTAssertFalse(hosts.contains("overpass.osm.ch"))
        XCTAssertFalse(hosts.contains("overpass.nchc.org.tw"))
        XCTAssertTrue(hosts.contains("overpass-api.de"))
        XCTAssertEqual(Set(hosts).count, hosts.count)
    }

    func testOverpassFormEncodingPreservesPlusAndAmpersand() throws {
        let query = "[out:json];nwr[name=\"A+B & C\"];out;"
        let body = try XCTUnwrap(String(data: OverpassConfiguration.formBody(query: query), encoding: .utf8))
        XCTAssertFalse(body.contains("+"))
        XCTAssertFalse(body.dropFirst(5).contains("&"))
        XCTAssertEqual(String(body.dropFirst(5)).removingPercentEncoding, query)
    }

    func testClosestReasonsAreShownFirst() {
        let result = decision(location(), [point(0.0004, kind: .school), point(0.0001)])
        XCTAssertTrue(result.blocked)
        XCTAssertTrue(result.message.hasPrefix("Детская площадка —"))
        XCTAssertTrue(result.message.contains("Школа —"))
    }

    func testNearbyDistanceTextUsesMeasuredDistance() {
        XCTAssertEqual(RestrictedPlaceSummary(id: "fixture", kind: .playground,
                                               name: nil, distance: 36).distanceText, "36 м")
        XCTAssertEqual(RestrictedPlaceSummary(id: "fixture", kind: .playground,
                                               name: nil, distance: 1_250).distanceText, "1.3 км")
    }

    func testNearestSummaryContainsThreeClosestUniqueCategories() {
        let places = [
            point(0.0010, kind: .kindergarten),
            point(0.0002, kind: .school),
            point(0.0003, kind: .school),
            point(0.0004, kind: .police),
            point(0.0008, kind: .security)
        ]
        let result = decision(location(), places)
        XCTAssertEqual(result.nearby.count, 3)
        XCTAssertEqual(result.nearby.map(\.kind), [.school, .police, .security])
        XCTAssertEqual(result.nearby.map(\.distance).sorted(), result.nearby.map(\.distance))
    }

    func testOSMFixturesClassifyAndBlockAtTheirCoordinates() {
        // Synthetic deterministic fixtures. No live network or real place
        // names are embedded in the public test bundle.
        let fixtures: [(id: String, name: String, coordinate: OSMCoordinate,
                        tags: [String: String], kind: RestrictedPlaceKind)] = [
            ("fixture-kindergarten", "Тестовый детский сад",
             .init(lat: 55.7471650, lon: 37.2175018),
             ["amenity": "kindergarten", "name": "Тестовый детский сад"], .kindergarten),
            ("fixture-school", "Тестовая школа",
             .init(lat: 52.6164547, lon: 49.6578119),
             ["amenity": "school", "name": "Тестовая школа"], .school),
            ("fixture-police", "Тестовый пункт полиции",
             .init(lat: 53.5764585, lon: 39.6221460),
             ["amenity": "police", "name": "Тестовый пункт полиции"], .police),
            ("fixture-security", "Тестовый объект безопасности",
             .init(lat: 54.0749374, lon: 34.2971248),
             ["government": "security", "name": "Тестовый объект безопасности"], .security),
            ("fixture-administration", "Тестовая администрация",
             .init(lat: 55.5945006, lon: 39.6695218),
             ["amenity": "townhall", "name": "Тестовая администрация"], .administration)
        ]

        for fixture in fixtures {
            XCTAssertEqual(RestrictedPlaceKind.classify(fixture.tags), fixture.kind, fixture.name)
            let place = RestrictedPlace(id: fixture.id, kind: fixture.kind, name: fixture.name,
                                        point: fixture.coordinate, lines: [], outerRings: [], innerRings: [])
            let current = location(fixture.coordinate.lat, fixture.coordinate.lon, accuracy: 1)
            let result = decisionAt(current, [place])
            XCTAssertTrue(result.blocked, fixture.name)
            XCTAssertTrue(result.message.contains(fixture.kind.singular), result.message)
        }
    }

    func testOSMFixtureUsesConfiguredBoundaryDistance() {
        let coordinate = OSMCoordinate(lat: 55.7471650, lon: 37.2175018)
        let place = RestrictedPlace(id: "fixture-kindergarten", kind: .kindergarten,
                                    name: "Тестовый детский сад", point: coordinate,
                                    lines: [], outerRings: [], innerRings: [])
        let center = location(coordinate.lat, coordinate.lon, accuracy: 1)
        XCTAssertTrue(decisionAt(offset(center, northMeters: 64), [place]).blocked)
        XCTAssertFalse(decisionAt(offset(center, northMeters: 66), [place]).blocked)

        var settings = enabled
        settings.radii[RestrictedPlaceKind.kindergarten.rawValue] = 120
        XCTAssertTrue(decisionAt(offset(center, northMeters: 110), [place], settings: settings).blocked)
    }

    func testDistanceProtectionIsBetweenEventsNotEventPhotos() {
        let previousEvent = location()
        let nearby = location(0, 0.0001)

        // The first photo starts an event and has no previous event anchor.
        XCTAssertNil(EventDistancePolicy.denialReason(current: nearby, lastEvent: nil,
                                                       enabled: true, minimumDistance: 30,
                                                       continuingEvent: false, now: now))
        // The second photo belongs to the same event and is allowed at the
        // same location, even when it is closer than the threshold.
        XCTAssertNil(EventDistancePolicy.denialReason(current: nearby, lastEvent: previousEvent,
                                                       enabled: true, minimumDistance: 30,
                                                       continuingEvent: true, now: now))
        // A new event at the same location is blocked until it moves away.
        let reason = EventDistancePolicy.denialReason(current: nearby, lastEvent: previousEvent,
                                                      enabled: true, minimumDistance: 30,
                                                      continuingEvent: false, now: now)
        XCTAssertTrue(reason?.contains("последнего события") == true)
        XCTAssertTrue(reason?.contains("минимум 30 м") == true)
        XCTAssertNil(EventDistancePolicy.denialReason(current: location(0, 0.0004), lastEvent: previousEvent,
                                                       enabled: true, minimumDistance: 30,
                                                       continuingEvent: false, now: now))
    }

    func testDistanceProtectionFailsClosedWhenNewEventCannotBeChecked() {
        XCTAssertTrue(EventDistancePolicy.denialReason(current: nil, lastEvent: location(),
                                                        enabled: true, minimumDistance: 30,
                                                        continuingEvent: false, now: now) != nil)
        XCTAssertNil(EventDistancePolicy.denialReason(current: nil, lastEvent: location(),
                                                       enabled: true, minimumDistance: 30,
                                                       continuingEvent: true, now: now))
    }

    @MainActor func testCameraRejectsCaptureBeforeStartingHardwareWhenVerificationIsPaused() {
        let previous = SettingsStore.shared.restrictedPlaces
        defer { SettingsStore.shared.restrictedPlaces = previous }
        SettingsStore.shared.restrictedPlaces = enabled
        RestrictedPlacesMonitor.shared.stop()
        let camera = CameraViewModel()
        camera.capturePhoto { _, _, _ in XCTFail("Capture must not reach completion while zones are unverified") }
        XCTAssertTrue(camera.error?.contains("приостановлена") == true)
        XCTAssertFalse(camera.isCapturing)
        XCTAssertNil(camera.pendingContext)
    }
}
