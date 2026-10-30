import CoreLocation

/// Runtime demand contains no coordinates and is not persisted. Force stop
/// clears both reasons for updating; releasing a camera clears only its own.
struct LocationUpdateDemand: Equatable {
    var continuousEnabled = false
    var foregroundRequested = false
    mutating func stop() { continuousEnabled = false; foregroundRequested = false }
}

enum LocationUpdatePolicy {
    struct Plan: Equatable {
        let updateLocation: Bool
        let updateHeading: Bool
        let backgroundAllowed: Bool
    }
    static func evaluate(demand: LocationUpdateDemand, authorization: CLAuthorizationStatus,
                         appInForeground: Bool, hasBackgroundCapability: Bool) -> Plan {
        let authorized = authorization == .authorizedAlways || authorization == .authorizedWhenInUse
        let background = demand.continuousEnabled && authorization == .authorizedAlways && hasBackgroundCapability
        return Plan(updateLocation: authorized && ((appInForeground && (demand.continuousEnabled || demand.foregroundRequested)) || background),
                    updateHeading: authorized && appInForeground && demand.foregroundRequested,
                    backgroundAllowed: background)
    }
}
