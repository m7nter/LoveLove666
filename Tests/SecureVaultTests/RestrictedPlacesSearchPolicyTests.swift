import XCTest
import CoreLocation
@testable import SecureVault

final class RestrictedPlacesSearchPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let settings = RestrictedPlaceSettings(enabled: true)
    private func user(north: Double = 0, speed: Double = -1) -> CLLocation {
        .init(coordinate: .init(latitude: north / 110_574, longitude: 0), altitude: 0,
            horizontalAccuracy: 2, verticalAccuracy: 1, course: 0, speed: speed, timestamp: now)
    }
    private func snapshot(radius: Double = 650) -> RestrictedPlacesSnapshot {
        .init(center: user(), radius: radius, fetchedAt: now, places: [])
    }
    func testDefaultOverviewIs500AndPrefetchStaysBelowOneKilometre() {
        XCTAssertEqual(RestrictedPlacesSearchPolicy.detailRadius(location: user(), settings: settings), 500)
        XCTAssertEqual(RestrictedPlacesSearchPolicy.requestRadius(location: user(), settings: settings), 650)
        let driving = RestrictedPlacesSearchPolicy.requestRadius(location: user(speed: 30), settings: settings)
        XCTAssertEqual(driving, 860)
        XCTAssertEqual(RestrictedPlacesSearchPolicy.requestRadius(location: user(speed: 100), settings: settings), 900)
    }
    func testLargeConfiguredProtectionDistanceAlwaysRemainsCovered() {
        var custom = settings; custom.radii["police"] = 1_000
        XCTAssertEqual(RestrictedPlacesSearchPolicy.detailRadius(location: user(), settings: custom), 1_002)
        XCTAssertGreaterThan(RestrictedPlacesSearchPolicy.requestRadius(location: user(), settings: custom), 1_015)
        let police = RestrictedPlace(id: "police", kind: .police, name: nil,
            point: .init(lat: 800 / 110_574.0, lon: 0), lines: [], outerRings: [], innerRings: [])
        let data = RestrictedPlacesSnapshot(center: user(), radius: 1_200, fetchedAt: now, places: [police])
        XCTAssertTrue(RestrictedPlacesPolicy.evaluate(location: user(), settings: custom, snapshot: data, now: now).blocked)
        XCTAssertEqual(RestrictedPlacesRadarPolicy.places(location: user(), settings: custom, snapshot: data, now: now)?.count, 1)
    }
    func testMovementAndExplicitRetryRefreshWithoutHammeringStationaryRequests() {
        let data = snapshot()
        let ready = now.addingTimeInterval(-1)
        XCTAssertFalse(RestrictedPlacesSearchPolicy.shouldRequest(location: user(), settings: settings,
            snapshot: data, now: now, notBefore: ready, failureCount: 0))
        XCTAssertTrue(RestrictedPlacesSearchPolicy.shouldRequest(location: user(north: 110), settings: settings,
            snapshot: data, now: now, notBefore: ready, failureCount: 0))
        XCTAssertTrue(RestrictedPlacesSearchPolicy.shouldRequest(location: user(), settings: settings,
            snapshot: data, now: now, notBefore: now.addingTimeInterval(3), failureCount: 0, force: true))
    }
    func testLostCoverageBypassesSuccessCooldownButPreservesFailureBackoff() {
        let moved = user(north: 700)
        let wait = now.addingTimeInterval(3)
        XCTAssertTrue(RestrictedPlacesSearchPolicy.shouldRequest(location: moved, settings: settings,
            snapshot: snapshot(), now: now, notBefore: wait, failureCount: 0))
        XCTAssertFalse(RestrictedPlacesSearchPolicy.shouldRequest(location: moved, settings: settings,
            snapshot: snapshot(), now: now, notBefore: wait, failureCount: 1))
    }
    func testMovingOutsidePrefetchOnlyClaimsTheRemainingVerifiedCircle() throws {
        let moved = user(north: 250)
        let available = RestrictedPlacesSearchPolicy.visibleRadius(location: moved, settings: settings, snapshot: snapshot())
        XCTAssertEqual(available, 400, accuracy: 1)
        let farther = RestrictedPlace(id: "outside-query", kind: .playground, name: nil,
            point: .init(lat: 700 / 110_574.0, lon: 0), lines: [], outerRings: [], innerRings: [])
        let data = RestrictedPlacesSnapshot(center: user(), radius: 650, fetchedAt: now, places: [farther])
        XCTAssertEqual(RestrictedPlacesRadarPolicy.places(location: moved, settings: settings, snapshot: data, now: now)?.count, 0)
    }
    func testFailedExplicitRefreshRetriesAfterBackoffEvenWhenPreviousSnapshotIsStillUsable() {
        XCTAssertFalse(RestrictedPlacesSearchPolicy.shouldRequest(location: user(), settings: settings,
            snapshot: snapshot(), now: now, notBefore: now.addingTimeInterval(10), failureCount: 1))
        XCTAssertTrue(RestrictedPlacesSearchPolicy.shouldRequest(location: user(), settings: settings,
            snapshot: snapshot(), now: now, notBefore: now.addingTimeInterval(-1), failureCount: 1))
    }
    func testOfflineSpatialIndexDoesNotLeakDistantCategorySummaries() {
        let distant = RestrictedPlace(id: "far-police", kind: .police, name: nil,
            point: .init(lat: 2_000 / 110_574.0, lon: 0), lines: [], outerRings: [], innerRings: [])
        let bounds = OfflineRegionBounds(south: -1, west: -1, north: 1, east: 1)
        let data = RestrictedPlacesSnapshot(center: user(), radius: 0, fetchedAt: now, places: [distant],
            offlineBounds: bounds, index: RestrictedPlaceIndex([distant]))
        XCTAssertFalse(RestrictedPlaceIndex([distant]).near(user(), radius: 500).isEmpty,
            "The coarse cell deliberately returns a superset")
        let decision = RestrictedPlacesPolicy.evaluate(location: user(), settings: settings, snapshot: data, now: now)
        XCTAssertFalse(decision.blocked)
        XCTAssertTrue(decision.nearby.isEmpty)
    }
    func testOfflineEdgeNeverClaimsMoreAreaThanWasDownloaded() {
        let bounds = OfflineRegionBounds(south: -0.01, west: -0.01, north: 0.01, east: 0.01)
        let nearEdge = CLLocation(coordinate: .init(latitude: 0.009, longitude: 0), altitude: 0,
            horizontalAccuracy: 2, verticalAccuracy: 1, timestamp: now)
        let data = RestrictedPlacesSnapshot(center: user(), radius: 0, fetchedAt: now, places: [], offlineBounds: bounds)
        XCTAssertTrue(data.covers(nearEdge, settings: settings, now: now))
        XCTAssertEqual(RestrictedPlacesSearchPolicy.visibleRadius(location: nearEdge, settings: settings, snapshot: data), 110, accuracy: 0.01)
    }
}
