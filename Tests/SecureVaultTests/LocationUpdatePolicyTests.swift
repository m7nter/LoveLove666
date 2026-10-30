import XCTest
import CoreLocation
@testable import SecureVault

final class LocationUpdatePolicyTests: XCTestCase {
    func testContinuousGPSWarmsCalculatorWithoutRunningCompass() {
        let plan = LocationUpdatePolicy.evaluate(demand: .init(continuousEnabled: true, foregroundRequested: false),
            authorization: .authorizedWhenInUse, appInForeground: true, hasBackgroundCapability: true)
        XCTAssertTrue(plan.updateLocation)
        XCTAssertFalse(plan.updateHeading)
        XCTAssertFalse(plan.backgroundAllowed)
    }

    func testBackgroundRequiresAllThreeConditions() {
        for enabled in [true, false] {
            for capability in [true, false] {
                for authorization in [CLAuthorizationStatus.authorizedAlways, .authorizedWhenInUse, .denied, .restricted, .notDetermined] {
                    let plan = LocationUpdatePolicy.evaluate(demand: .init(continuousEnabled: enabled, foregroundRequested: true),
                        authorization: authorization, appInForeground: false, hasBackgroundCapability: capability)
                    let expected = enabled && capability && authorization == .authorizedAlways
                    XCTAssertEqual(plan.backgroundAllowed, expected)
                    XCTAssertEqual(plan.updateLocation, expected)
                    XCTAssertFalse(plan.updateHeading)
                }
            }
        }
    }

    func testCameraReleasePreservesContinuousDemandButForceStopRevokesBoth() {
        var demand = LocationUpdateDemand(continuousEnabled: true, foregroundRequested: true)
        demand.foregroundRequested = false
        let released = LocationUpdatePolicy.evaluate(demand: demand, authorization: .authorizedAlways,
            appInForeground: false, hasBackgroundCapability: true)
        XCTAssertTrue(released.updateLocation)
        XCTAssertFalse(released.updateHeading)
        demand.stop()
        for foreground in [true, false] {
            let stopped = LocationUpdatePolicy.evaluate(demand: demand, authorization: .authorizedAlways,
                appInForeground: foreground, hasBackgroundCapability: true)
            XCTAssertEqual(stopped, .init(updateLocation: false, updateHeading: false, backgroundAllowed: false))
        }
        demand.continuousEnabled = true
        XCTAssertTrue(LocationUpdatePolicy.evaluate(demand: demand, authorization: .authorizedAlways,
            appInForeground: false, hasBackgroundCapability: true).updateLocation)
    }

    func testDisablingWarmModePreservesCameraOnlyWhileForeground() {
        let demand = LocationUpdateDemand(continuousEnabled: false, foregroundRequested: true)
        for authorization in [CLAuthorizationStatus.authorizedAlways, .authorizedWhenInUse] {
            let camera = LocationUpdatePolicy.evaluate(demand: demand, authorization: authorization,
                appInForeground: true, hasBackgroundCapability: true)
            XCTAssertEqual(camera, .init(updateLocation: true, updateHeading: true, backgroundAllowed: false))
            let background = LocationUpdatePolicy.evaluate(demand: demand, authorization: authorization,
                appInForeground: false, hasBackgroundCapability: true)
            XCTAssertEqual(background, .init(updateLocation: false, updateHeading: false, backgroundAllowed: false))
        }
    }

    func testDeniedRestrictedAndUndeterminedCannotStartAnySensor() {
        for authorization in [CLAuthorizationStatus.denied, .restricted, .notDetermined] {
            for foreground in [true, false] {
                let plan = LocationUpdatePolicy.evaluate(demand: .init(continuousEnabled: true, foregroundRequested: true),
                    authorization: authorization, appInForeground: foreground, hasBackgroundCapability: true)
                XCTAssertEqual(plan, .init(updateLocation: false, updateHeading: false, backgroundAllowed: false))
            }
        }
    }

    @MainActor
    func testLateCoreLocationCallbackAfterForceStopCannotRestoreCoordinatesOrRestartUpdates() {
        let manager = LocationManager()
        manager.location = CLLocation(latitude: 55, longitude: 37)
        manager.stop()
        let driver = CLLocationManager()
        manager.locationManager(driver, didUpdateLocations: [CLLocation(latitude: 56, longitude: 38)])
        manager.locationManagerDidChangeAuthorization(driver)
        XCTAssertNil(manager.location)
        XCTAssertNil(manager.heading)
        XCTAssertFalse(manager.isUpdatingLocation)
        XCTAssertFalse(manager.backgroundUpdatesActive)
    }
}
