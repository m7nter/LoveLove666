import CoreLocation
import Foundation

enum RestrictedPlacesRadarPolicy {
    /// nil means unverified, while an empty array is a verified empty area.
    /// The radar consumes the camera's snapshot and never starts a second query.
    static func places(location: CLLocation?, settings: RestrictedPlaceSettings,
                       snapshot: RestrictedPlacesSnapshot?, now: Date = Date()) -> [RestrictedPlace]? {
        guard settings.enabled, RestrictedPlaceKind.allCases.contains(where: settings.includes),
              RestrictedPlacesPolicy.locationProblem(location, settings: settings, now: now) == nil,
              let location, let snapshot, snapshot.covers(location, settings: settings, now: now),
              !(settings.blockOnEmptyOnlineResponse && snapshot.isEmptyOnlineResponse) else { return nil }
        let radius = max(1_000, settings.maximumRadius + location.horizontalAccuracy)
        let candidates = snapshot.index?.near(location, radius: radius) ?? snapshot.places
        return candidates.filter { settings.includes($0.kind) }
            .map { ($0, $0.distance(from: location)) }
            .filter { $0.1.isFinite && $0.1 <= radius }
            .sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 < $1.1 }
            .map { $0.0 }
    }
}
