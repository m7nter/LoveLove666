import Foundation
import CoreLocation

/// Index each complete geometry's bounding box, so large containing territories
/// remain candidates even when their vertices are far from the current position.
final class RestrictedPlaceIndex {
    private let places: [RestrictedPlace]
    private var cells: [String: Set<Int>] = [:]
    private var global: Set<Int> = []
    private let step = 0.025
    init(_ places: [RestrictedPlace]) {
        self.places = places
        for (index, place) in places.enumerated() {
            let points = place.lines.flatMap { $0 } + place.outerRings.flatMap { $0 } + place.innerRings.flatMap { $0 } + (place.point.map { [$0] } ?? [])
            guard let south = points.map(\.lat).min(), let north = points.map(\.lat).max(),
                  let west = points.map(\.lon).min(), let east = points.map(\.lon).max() else { global.insert(index); continue }
            let x0 = Int(floor(west / step)), x1 = Int(floor(east / step))
            let y0 = Int(floor(south / step)), y1 = Int(floor(north / step))
            if east - west > 180 || (x1 - x0 + 1) * (y1 - y0 + 1) > 4000 { global.insert(index); continue }
            for x in x0...x1 { for y in y0...y1 { cells["\(x)/\(y)", default: []].insert(index) } }
        }
    }
    func near(_ location: CLLocation, radius: Double) -> [RestrictedPlace] {
        let c = location.coordinate
        let dy = radius / 110_000, dx = radius / max(100, 110_000 * cos(c.latitude * .pi / 180))
        let y0 = Int(floor((c.latitude - dy) / step)), y1 = Int(floor((c.latitude + dy) / step))
        var ranges = [(max(-180, c.longitude - dx), min(180, c.longitude + dx))]
        if c.longitude - dx < -180 { ranges.append((c.longitude - dx + 360, 180)) }
        if c.longitude + dx > 180 { ranges.append((-180, c.longitude + dx - 360)) }
        var indices = global
        for (west, east) in ranges {
            for x in Int(floor(west / step))...Int(floor(east / step)) {
                for y in y0...y1 { indices.formUnion(cells["\(x)/\(y)"] ?? []) }
            }
        }
        return indices.map { places[$0] }
    }
}
