import Foundation
import CoreLocation

/// A compact view around the current position, with enough prefetched geometry
/// to refresh while walking/driving. Configured protection distances take priority.
enum RestrictedPlacesSearchPolicy {
    static let standardRadius = 500.0
    static let movementThreshold = 100.0
    static let successCooldown = 3.0

    static func detailRadius(location: CLLocation, settings: RestrictedPlaceSettings) -> Double {
        max(standardRadius, settings.maximumRadius + max(0, location.horizontalAccuracy))
    }

    static func requestRadius(location: CLLocation, settings: RestrictedPlaceSettings) -> Double {
        let speed = location.speed.isFinite ? max(0, location.speed) : 0
        let padding = max(150, min(400, speed * 12))
        return min(1_500, ceil(max(standardRadius, settings.maximumRadius + settings.accuracyLimit) + padding))
    }

    /// Only claim the circle fully covered by the cached answer. Movement must
    /// not make an unchecked leading edge look like verified absence of objects.
    static func visibleRadius(location: CLLocation, settings: RestrictedPlaceSettings,
                              snapshot: RestrictedPlacesSnapshot) -> Double {
        let covered: Double
        if let tiles = snapshot.offlineCoverage {
            covered = tiles.map { $0.containedRadius(at: location.coordinate) }.max() ?? 0
        } else if let bounds = snapshot.offlineBounds {
            covered = bounds.containedRadius(at: location.coordinate)
        } else {
            covered = max(0, snapshot.radius - snapshot.center.distance(from: location))
        }
        return max(0, min(detailRadius(location: location, settings: settings), covered))
    }

    static func shouldRequest(location: CLLocation, settings: RestrictedPlaceSettings,
                              snapshot: RestrictedPlacesSnapshot?, now: Date,
                              notBefore: Date, failureCount: Int, force: Bool = false) -> Bool {
        if force { return true }
        // Network failures retain backoff even after moving outside coverage.
        if failureCount > 0, now < notBefore { return false }
        guard let snapshot, snapshot.covers(location, settings: settings, now: now) else { return true }
        guard now >= notBefore else { return false }
        return failureCount > 0 || now.timeIntervalSince(snapshot.fetchedAt) >= 480
            || snapshot.center.distance(from: location) >= movementThreshold
            || visibleRadius(location: location, settings: settings, snapshot: snapshot)
                + 0.01 < detailRadius(location: location, settings: settings)
    }
}
