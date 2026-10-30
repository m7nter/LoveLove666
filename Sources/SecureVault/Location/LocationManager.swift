import CoreLocation
import Combine
import UIKit

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationManager()

    @Published var location: CLLocation?
    @Published var heading: CLHeading?
    @Published private(set) var authorized = false
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var accuracyAuthorization: CLAccuracyAuthorization = .reducedAccuracy
    @Published private(set) var backgroundUpdatesActive = false
    @Published private(set) var isUpdatingLocation = false
    @Published private(set) var lastError: String?

    private let clManager = CLLocationManager()
    private var demand = LocationUpdateDemand()
    private var updatingHeading = false
    private var requestedWhenInUse = false
    private var requestedAlways = false
    private var subscriptions: Set<AnyCancellable> = []

    override init() {
        super.init()
        clManager.desiredAccuracy = kCLLocationAccuracyBest
        clManager.distanceFilter = kCLDistanceFilterNone
        clManager.pausesLocationUpdatesAutomatically = false
        clManager.showsBackgroundLocationIndicator = true
        clManager.delegate = self
        authorizationStatus = clManager.authorizationStatus
        accuracyAuthorization = clManager.accuracyAuthorization
        authorized = authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
        for notification in [UIApplication.didBecomeActiveNotification, UIApplication.didEnterBackgroundNotification] {
            NotificationCenter.default.publisher(for: notification).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.refreshAuthorization()
                    self?.applyUpdatePolicy()
                }.store(in: &subscriptions)
        }
    }

    /// Camera demand includes heading. Closing the camera releases only this
    /// demand; the optional continuous GPS session may remain active.
    func requestAndStart() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard (try? VaultGate.shared.withAccess { true }) == true else { return }
        demand.foregroundRequested = true
        refreshAuthorization()
        applyUpdatePolicy()
    }

    func releaseForegroundUpdates() {
        dispatchPrecondition(condition: .onQueue(.main))
        demand.foregroundRequested = false
        applyUpdatePolicy()
    }

    /// Root applies the persisted preference only after setup and while
    /// lifecycle access is permitted. This method never reads vault data.
    func setContinuousUpdatesEnabled(_ enabled: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        demand.continuousEnabled = enabled
        refreshAuthorization()
        applyUpdatePolicy()
    }

    /// Explicit settings action. Normal startup requests When In Use once;
    /// an Always upgrade is never requested automatically in a loop.
    func requestContinuousAuthorization() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard demand.continuousEnabled, UIApplication.shared.applicationState == .active else { return }
        refreshAuthorization()
        switch authorizationStatus {
        case .notDetermined, .authorizedWhenInUse:
            guard !requestedAlways else { return }
            requestedAlways = true
            clManager.requestAlwaysAuthorization()
        case .authorizedAlways, .denied, .restricted:
            break
        @unknown default:
            break
        }
        applyUpdatePolicy()
    }

    /// Force stop is used for erasure. It revokes both runtime demands, so a
    /// queued authorization callback cannot restart GPS. Root must explicitly
    /// reapply the preference after a permitted new setup.
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        demand.stop()
        applyUpdatePolicy()
        location = nil; heading = nil; lastError = nil
    }

    private var hasBackgroundCapability: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("location") == true
    }

    private func refreshAuthorization() {
        let status = clManager.authorizationStatus
        if authorizationStatus != status { authorizationStatus = status }
        let accuracy = clManager.accuracyAuthorization
        if accuracyAuthorization != accuracy { accuracyAuthorization = accuracy }
        let allowed = status == .authorizedWhenInUse || status == .authorizedAlways
        if authorized != allowed { authorized = allowed }
    }

    private func applyUpdatePolicy() {
        let foreground = UIApplication.shared.applicationState != .background
        if (demand.continuousEnabled || demand.foregroundRequested), authorizationStatus == .notDetermined,
           UIApplication.shared.applicationState == .active, !requestedWhenInUse, !requestedAlways {
            requestedWhenInUse = true
            clManager.requestWhenInUseAuthorization()
        }
        let plan = LocationUpdatePolicy.evaluate(demand: demand, authorization: authorizationStatus,
            appInForeground: foreground, hasBackgroundCapability: hasBackgroundCapability)
        // Setting this true without UIBackgroundModes=location can terminate
        // an iOS app. The plan requires that capability and Always permission.
        if clManager.allowsBackgroundLocationUpdates != plan.backgroundAllowed {
            clManager.allowsBackgroundLocationUpdates = plan.backgroundAllowed
        }
        if backgroundUpdatesActive != plan.backgroundAllowed { backgroundUpdatesActive = plan.backgroundAllowed }
        if plan.updateLocation != isUpdatingLocation {
            isUpdatingLocation = plan.updateLocation
            if plan.updateLocation { clManager.startUpdatingLocation() }
            else { clManager.stopUpdatingLocation() }
        }
        let needsHeading = plan.updateHeading && CLLocationManager.headingAvailable()
        if needsHeading != updatingHeading {
            updatingHeading = needsHeading
            if needsHeading { clManager.startUpdatingHeading() }
            else { clManager.stopUpdatingHeading(); heading = nil }
        }
        if !plan.updateLocation { location = nil }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // A callback already queued before stop must not repopulate coordinates
        // which were cleared by erasure. Ignore out-of-order cached samples.
        guard isUpdatingLocation,
              let latest = locations.filter({ CLLocationCoordinate2DIsValid($0.coordinate) })
                .max(by: { $0.timestamp < $1.timestamp }),
              location == nil || latest.timestamp >= location!.timestamp else { return }
        location = latest
        if lastError != nil { lastError = nil }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard updatingHeading else { return }
        heading = newHeading
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refreshAuthorization()
        applyUpdatePolicy()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard isUpdatingLocation else { return }
        if let error = error as? CLError, error.code == .denied {
            clManager.stopUpdatingLocation(); clManager.stopUpdatingHeading()
            isUpdatingLocation = false; updatingHeading = false
            backgroundUpdatesActive = false
            location = nil; heading = nil
            lastError = "Доступ к геопозиции запрещён. Проверьте разрешение в настройках iOS."
        } else {
            // A temporary locationUnknown does not tear down a warmed GPS
            // session. Capture independently checks the sample age/accuracy.
            lastError = "GPS пока не может определить координаты. Ожидаем новый сигнал."
        }
    }

    func compassDirection(from degrees: Double) -> String {
        let dirs = ["С","СВ","В","ЮВ","Ю","ЮЗ","З","СЗ"]
        let idx = Int((degrees + 22.5) / 45) % 8
        return dirs[idx]
    }
}
