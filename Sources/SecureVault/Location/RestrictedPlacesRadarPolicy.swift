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
        var nearby: [(place: RestrictedPlace, distance: Double)] = []
        for place in candidates where settings.includes(place.kind) {
            let distance = place.distance(from: location)
            if distance.isFinite && distance <= radius {
                nearby.append((place: place, distance: distance))
            }
        }
        nearby.sort { left, right in
            if left.distance == right.distance { return left.place.id < right.place.id }
            return left.distance < right.distance
        }
        return nearby.map { $0.place }
    }
}
