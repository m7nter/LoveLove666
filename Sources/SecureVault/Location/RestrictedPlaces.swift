import Foundation
import CoreLocation
import MapKit

enum RestrictedPlaceKind: String, CaseIterable, Codable, Identifiable {
    case playground, kindergarten, school, sports, police, security, administration, court, prosecutor, recruitment, military, government
    var id: String { rawValue }
    var title: String {
        switch self {
        case .playground: return "Детские площадки"
        case .kindergarten: return "Детские сады"
        case .school: return "Школы"
        case .sports: return "Спортплощадки"
        case .police: return "Полиция и МВД"
        case .security: return "ФСБ и другие силовые службы"
        case .administration: return "Администрации"
        case .court: return "Суды"
        case .prosecutor: return "Прокуратуры"
        case .recruitment: return "Военкоматы"
        case .military: return "Военные территории"
        case .government: return "Другие госучреждения"
        }
    }
    var singular: String {
        switch self {
        case .playground: return "Детская площадка"
        case .kindergarten: return "Детский сад"
        case .school: return "Школа"
        case .sports: return "Спортплощадка"
        case .police: return "Полиция / МВД"
        case .security: return "Силовая служба"
        case .administration: return "Администрация"
        case .court: return "Суд"
        case .prosecutor: return "Прокуратура"
        case .recruitment: return "Военкомат"
        case .military: return "Военная территория"
        case .government: return "Госучреждение"
        }
    }
    var defaultRadius: Double { [.playground, .kindergarten, .school, .sports].contains(self) ? 65 : 100 }

    static func classify(_ tags: [String: String]) -> RestrictedPlaceKind? {
        // A specific service wins over a generic office=government / amenity=police.
        let text = ["name", "name:ru", "operator", "operator:ru", "official_name"].compactMap { tags[$0] }.joined(separator: " ").lowercased()
        func matches(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        if tags["government"] == "recruitment" || matches("военком|военн.*комиссар|recruitment") { return .recruitment }
        if tags["government"] == "prosecutor" || matches("прокурат|prosecutor") { return .prosecutor }
        if tags["amenity"] == "courthouse" || tags["government"] == "court" { return .court }
        if ["security", "intelligence"].contains(tags["government"] ?? "") || matches("(^|[^а-яa-z])(фсб|уфсб|фсо|фсин|фссп|росгвард|омон|собр|следственн|fsb|security service)|федеральн.*служб.*(безопасност|охран|исполнения наказан)|национальн.*гварди|служб.*судебн.*пристав") { return .security }
        if tags["amenity"] == "police" || tags["police"] != nil || tags["government"] == "police" || matches("(^|[^а-яa-z])(мвд|умвд|омвд|гибдд|дпс|полици|police)|(министерств|управлен|отдел).*внутренн.*дел") { return .police }
        if tags["landuse"] == "military" || tags["military"] != nil || tags["government"] == "military" { return .military }
        if tags["amenity"] == "townhall" || tags["government"] == "administrative" || matches("администраци|мэрия") { return .administration }
        if tags["amenity"] == "kindergarten" || tags["building"] == "kindergarten" { return .kindergarten }
        if tags["amenity"] == "school" || tags["building"] == "school" { return .school }
        if tags["leisure"] == "playground" { return .playground }
        if ["pitch", "sports_centre", "stadium", "fitness_station", "track"].contains(tags["leisure"] ?? "") { return .sports }
        if tags["office"] == "government" || tags["government"] != nil { return .government }
        return nil
    }
}

struct RestrictedPlaceSettings: Codable, Equatable {
    var enabled = false
    var maximumAccuracy: Double = 15
    var disabledKinds: Set<RestrictedPlaceKind> = []
    var radii: [String: Double] = [:]
    func includes(_ kind: RestrictedPlaceKind) -> Bool { !disabledKinds.contains(kind) }
    func radius(for kind: RestrictedPlaceKind) -> Double { min(1000, max(1, radii[kind.rawValue] ?? kind.defaultRadius)) }
    var accuracyLimit: Double { min(50, max(3, maximumAccuracy)) }
    var maximumRadius: Double { RestrictedPlaceKind.allCases.filter(includes).map(radius).max() ?? 0 }
}

struct OSMCoordinate: Codable, Equatable {
    let lat: Double
    let lon: Double
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    var valid: Bool { lat.isFinite && lon.isFinite && CLLocationCoordinate2DIsValid(coordinate) }
}

struct RestrictedPlace: Codable {
    let id: String
    let kind: RestrictedPlaceKind
    let name: String?
    let point: OSMCoordinate?
    let lines: [[OSMCoordinate]]
    let outerRings: [[OSMCoordinate]]
    let innerRings: [[OSMCoordinate]]

    /// Nearest edge, or zero inside the mapped territory. Never use a polygon's centre.
    func distance(from location: CLLocation) -> Double {
        let origin = MKMapPoint(location.coordinate)
        let scale = MKMetersPerMapPointAtLatitude(location.coordinate.latitude)
        let world = MKMapRect.world.size.width
        func xy(_ coordinate: OSMCoordinate) -> CGPoint {
            let p = MKMapPoint(coordinate.coordinate)
            var dx = p.x - origin.x
            if dx > world / 2 { dx -= world }
            if dx < -world / 2 { dx += world }
            return CGPoint(x: dx * scale, y: (p.y - origin.y) * scale)
        }
        func contains(_ ring: [OSMCoordinate]) -> Bool {
            let points = ring.map(xy)
            guard points.count >= 4 else { return false }
            var inside = false
            for index in 1..<points.count {
                let a = points[index - 1], b = points[index]
                if (a.y > 0) != (b.y > 0), (b.x - a.x) * (-a.y) / (b.y - a.y) + a.x > 0 { inside.toggle() }
            }
            return inside
        }
        if outerRings.contains(where: contains) && !innerRings.contains(where: contains) { return 0 }
        var nearest = Double.infinity
        if let point { let p = xy(point); nearest = hypot(p.x, p.y) }
        for line in lines + outerRings + innerRings {
            let points = line.map(xy)
            if let p = points.first { nearest = min(nearest, hypot(p.x, p.y)) }
            for index in 1..<points.count {
                let a = points[index - 1], b = points[index]
                let dx = b.x - a.x, dy = b.y - a.y
                let length = dx * dx + dy * dy
                let t = length > 0 ? min(1, max(0, -(a.x * dx + a.y * dy) / length)) : 0
                nearest = min(nearest, hypot(a.x + t * dx, a.y + t * dy))
            }
        }
        return nearest
    }
}

enum RestrictedPlacesError: Error { case incompleteResponse, invalidGeometry }

enum RestrictedPlacesParser {
    private struct Response: Decodable { let remark: String?; let elements: [Element] }
    private struct Element: Decodable {
        let type: String; let id: Int64
        let lat: Double?; let lon: Double?
        let tags: [String: String]?
        let geometry: [OSMCoordinate]?
        let members: [Member]?
    }
    private struct Member: Decodable { let type: String; let role: String; let geometry: [OSMCoordinate]? }

    static func parse(_ data: Data) throws -> [RestrictedPlace] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        // Overpass can return HTTP 200 with a timeout remark and partial elements.
        guard response.remark == nil else { throw RestrictedPlacesError.incompleteResponse }
        return try response.elements.compactMap { element in
            let tags = element.tags ?? [:]
            guard let kind = RestrictedPlaceKind.classify(tags) else { return nil }
            var point: OSMCoordinate?
            var lines: [[OSMCoordinate]] = [], outer: [[OSMCoordinate]] = [], inner: [[OSMCoordinate]] = []
            if element.type == "node", let lat = element.lat, let lon = element.lon {
                let p = OSMCoordinate(lat: lat, lon: lon)
                guard p.valid else { throw RestrictedPlacesError.invalidGeometry }
                point = p
            } else if element.type == "way", let geometry = element.geometry, geometry.count >= 2 {
                guard geometry.allSatisfy(\.valid) else { throw RestrictedPlacesError.invalidGeometry }
                if geometry.first == geometry.last, tags["area"] != "no" { outer = [geometry] }
                else { lines = [geometry] }
            } else if element.type == "relation", let members = element.members {
                for role in ["outer", "inner"] {
                    let relevant = members.filter { $0.type == "way" && ($0.role == role || (role == "outer" && $0.role.isEmpty)) }
                    let fragments = try relevant.map { member -> [OSMCoordinate] in
                        guard let g = member.geometry, g.count >= 2, g.allSatisfy(\.valid) else { throw RestrictedPlacesError.invalidGeometry }
                        return g
                    }
                    let rings = try joinRings(fragments)
                    if role == "outer" { outer = rings } else { inner = rings }
                }
                guard !outer.isEmpty else { throw RestrictedPlacesError.invalidGeometry }
            } else { throw RestrictedPlacesError.invalidGeometry }
            return RestrictedPlace(id: "\(element.type)/\(element.id)", kind: kind,
                                   name: tags["name:ru"] ?? tags["name"], point: point,
                                   lines: lines, outerRings: outer, innerRings: inner)
        }
    }

    static func joinRings(_ fragments: [[OSMCoordinate]]) throws -> [[OSMCoordinate]] {
        var pending = fragments, result: [[OSMCoordinate]] = []
        while !pending.isEmpty {
            var ring = pending.removeFirst()
            while ring.first != ring.last {
                guard let index = pending.firstIndex(where: { $0.first == ring.last || $0.last == ring.last }) else {
                    throw RestrictedPlacesError.invalidGeometry
                }
                var next = pending.remove(at: index)
                if next.last == ring.last { next.reverse() }
                ring.append(contentsOf: next.dropFirst())
            }
            guard ring.count >= 4 else { throw RestrictedPlacesError.invalidGeometry }
            result.append(ring)
        }
        return result
    }
}

struct RestrictedPlacesSnapshot {
    let center: CLLocation
    let radius: Double
    let fetchedAt: Date
    let places: [RestrictedPlace]
    var offlineBounds: OfflineRegionBounds? = nil
    var index: RestrictedPlaceIndex? = nil
    func covers(_ location: CLLocation, settings: RestrictedPlaceSettings, now: Date) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        if let bounds = offlineBounds {
            return age >= 0 && age < 30 * 86400 && bounds.contains(location.coordinate, margin: settings.maximumRadius + location.horizontalAccuracy)
        }
        return age >= 0 && age < 600 && center.distance(from: location) + settings.maximumRadius + location.horizontalAccuracy < radius
    }
}

struct CaptureZoneDecision: Equatable {
    let blocked: Bool
    let message: String
    static let disabled = Self(blocked: false, message: "")
}

enum RestrictedPlacesPolicy {
    static func locationProblem(_ location: CLLocation?, settings: RestrictedPlaceSettings, now: Date) -> String? {
        guard let location, CLLocationCoordinate2DIsValid(location.coordinate), abs(location.coordinate.latitude) <= 85.05112878, location.horizontalAccuracy.isFinite,
              location.horizontalAccuracy >= 0, abs(location.timestamp.timeIntervalSince(now)) < 15 else {
            return "Нет свежих координат — проверка зон невозможна. Съёмка заблокирована."
        }
        guard location.horizontalAccuracy < settings.accuracyLimit else {
            return "Точность GPS ±\(Int(ceil(location.horizontalAccuracy))) м — нужна погрешность меньше \(Int(settings.accuracyLimit)) м. Съёмка заблокирована."
        }
        return nil
    }

    static func evaluate(location: CLLocation?, settings: RestrictedPlaceSettings, snapshot: RestrictedPlacesSnapshot?,
                         now: Date = Date(), unavailableReason: String = "Проверяем ближайшие территории…") -> CaptureZoneDecision {
        guard settings.enabled else { return .disabled }
        guard RestrictedPlaceKind.allCases.contains(where: settings.includes) else {
            return .init(blocked: true, message: "Выберите хотя бы один тип запретных зон в настройках.")
        }
        if let problem = locationProblem(location, settings: settings, now: now) { return .init(blocked: true, message: problem) }
        guard let location, let snapshot, snapshot.covers(location, settings: settings, now: now) else {
            return .init(blocked: true, message: unavailableReason + " Съёмка заблокирована.")
        }
        let nearby = snapshot.index?.near(location, radius: settings.maximumRadius + location.horizontalAccuracy) ?? snapshot.places
        let violations = nearby.filter { settings.includes($0.kind) }.compactMap { place -> (RestrictedPlace, Double, Bool)? in
            let distance = place.distance(from: location)
            let radius = settings.radius(for: place.kind)
            guard distance - location.horizontalAccuracy <= radius else { return nil }
            return (place, distance, distance > radius)
        }.sorted { $0.1 < $1.1 }
        guard !violations.isEmpty else { return .init(blocked: false, message: "Запретных зон по данным OpenStreetMap рядом не найдено") }
        let reasons = violations.prefix(3).map { place, distance, uncertain in
            "\(place.kind.singular) — \(Int(distance.rounded())) м" + (uncertain ? " (с учётом погрешности GPS)" : "")
        }.joined(separator: "\n")
        return .init(blocked: true, message: reasons + (violations.count > 3 ? "\nИ ещё \(violations.count - 3) зон" : ""))
    }
}
