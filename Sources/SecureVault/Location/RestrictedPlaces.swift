import Foundation
import CoreLocation
import MapKit

/// Only full-planet mirrors may answer a safety check for an arbitrary region.
/// In particular, overpass.osm.ch contains Switzerland only and a valid empty
/// reply outside it is not evidence that there are no restricted places.
enum OverpassConfiguration {
    static let worldwideEndpoints = [
        URL(string: "https://overpass.private.coffee/api/interpreter")!,
        URL(string: "https://overpass.openstreetmap.fr/api/interpreter")!,
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://lz4.overpass-api.de/api/interpreter")!,
        URL(string: "https://z.overpass-api.de/api/interpreter")!
    ]

    static func formBody(query: String) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return Data(("data=" + encoded).utf8)
    }
}

enum RestrictedPlaceKind: String, CaseIterable, Codable, Identifiable, Hashable {
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

    static let identifyingNameKeys = ["name", "name:ru", "operator", "operator:ru", "official_name"]

    /// Shared by PBF classification and bounded Overpass selections. Keeping
    /// these in one place prevents an alias recognized offline from silently
    /// disappearing online merely because office/government tags are absent.
    static func namePattern(for kind: RestrictedPlaceKind) -> String? {
        switch kind {
        case .recruitment: return "военком|военн.*комиссар|recruitment"
        case .prosecutor: return "прокурат|prosecutor"
        case .security: return "(^|[^а-яa-z])(фсб|уфсб|фсо|фсин|фссп|росгвард|омон|собр|следственн|fsb|security service)|федеральн.*служб.*(безопасност|охран|исполнения наказан)|национальн.*гварди|служб.*судебн.*пристав"
        case .police: return "(^|[^а-яa-z])(мвд|умвд|омвд|гибдд|дпс|полици|police)|(министерств|управлен|отдел).*внутренн.*дел"
        case .administration: return "администраци|мэрия"
        case .playground: return "детск.*площадк|игров.*площадк|playground"
        default: return nil
        }
    }

    /// ICU/PCRE boundaries used by the Swift classifier are not accepted by
    /// every Overpass regex engine when mixed with Cyrillic character classes.
    /// Use conservative word fragments for the remote filter and run the
    /// authoritative classifier again on the returned tags.
    static func overpassNamePattern(for kind: RestrictedPlaceKind) -> String? {
        switch kind {
        case .recruitment: return "военком|военн.*комиссар|recruitment"
        case .prosecutor: return "прокурат|prosecutor"
        case .security: return "фсб|уфсб|фсо|фсин|фссп|росгвард|омон|собр|следственн|fsb|security service|федеральн.*служб.*безопасност|федеральн.*служб.*охран|национальн.*гварди"
        case .police: return "мвд|умвд|омвд|гибдд|дпс|полици|police|министерств.*внутренн.*дел|управлен.*внутренн.*дел|отдел.*внутренн.*дел"
        case .administration: return "администраци|мэрия"
        case .playground: return "детск.*площадк|игров.*площадк|playground"
        default: return nil
        }
    }

    static func classify(_ tags: [String: String]) -> RestrictedPlaceKind? {
        // An explicit active facility type describes this object, while an
        // operator/name may merely identify its municipal or МВД owner.
        // education=* and amenity=* are equivalent active education schemas.
        if tags["amenity"] == "kindergarten" || tags["education"] == "kindergarten" { return .kindergarten }
        if tags["amenity"] == "school" || tags["education"] == "school" { return .school }
        // A specific service wins over a generic office=government / amenity=police.
        let text = identifyingNameKeys.compactMap { tags[$0] }.joined(separator: " ").lowercased()
        func matches(_ kind: RestrictedPlaceKind) -> Bool {
            guard let pattern = namePattern(for: kind) else { return false }
            return text.range(of: pattern, options: .regularExpression) != nil
        }
        if tags["government"] == "recruitment" || matches(.recruitment) { return .recruitment }
        if tags["government"] == "prosecutor" || matches(.prosecutor) { return .prosecutor }
        if tags["amenity"] == "courthouse" || tags["government"] == "court" { return .court }
        if ["security", "intelligence"].contains(tags["government"] ?? "") || matches(.security) { return .security }
        if tags["amenity"] == "police" || tags["police"] != nil || tags["government"] == "police" || matches(.police) { return .police }
        if tags["landuse"] == "military" || tags["military"] != nil || tags["government"] == "military" { return .military }
        if tags["amenity"] == "townhall" || tags["government"] == "administrative" || matches(.administration) { return .administration }
        // A building's original design remains a fallback; a current explicit
        // service above may occupy a repurposed school/kindergarten building.
        if tags["building"] == "kindergarten" { return .kindergarten }
        if tags["building"] == "school" { return .school }
        // OSM uses `leisure=playground` for the usual area, but imported
        // Russian datasets also contain playground nodes/ways with a
        // `playground=*` key and Russian names without the leisure tag.
        // Treat those as the same protected category so a mapped fence is not
        // silently missed just because the mapper used the alternative tag.
        if tags["leisure"] == "playground" || tags["playground"] != nil
            || matches(.playground) { return .playground }
        if ["pitch", "sports_centre", "stadium", "fitness_station", "track"].contains(tags["leisure"] ?? "") { return .sports }
        if tags["office"] == "government" || tags["government"] != nil { return .government }
        return nil
    }
}

enum RestrictedPlacesCheckMode: String, CaseIterable, Codable, Identifiable {
    case automatic
    case online
    case offline

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Автоматически"
        case .online: return "Онлайн"
        case .offline: return "Офлайн"
        }
    }
    var description: String {
        switch self {
        case .automatic: return "Сначала используем OSM онлайн, а при отсутствии сети — готовую офлайн-базу."
        case .online: return "Карту скачивать не нужно. Проверка выполняется через интернет перед съёмкой."
        case .offline: return "Работает без сети, но требует полностью загруженную базу зон региона."
        }
    }
}

struct RestrictedPlaceSettings: Codable, Equatable {
    var enabled = false
    var maximumAccuracy: Double = 15
    var checkMode: RestrictedPlacesCheckMode = .automatic
    var blockOnEmptyOnlineResponse = false
    var disabledKinds: Set<RestrictedPlaceKind> = []
    var radii: [String: Double] = [:]

    init(enabled: Bool = false, maximumAccuracy: Double = 15,
         checkMode: RestrictedPlacesCheckMode = .automatic,
         blockOnEmptyOnlineResponse: Bool = false,
         disabledKinds: Set<RestrictedPlaceKind> = [], radii: [String: Double] = [:]) {
        self.enabled = enabled
        self.maximumAccuracy = maximumAccuracy
        self.checkMode = checkMode
        self.blockOnEmptyOnlineResponse = blockOnEmptyOnlineResponse
        self.disabledKinds = disabledKinds
        self.radii = radii
    }

    private enum CodingKeys: String, CodingKey { case enabled, maximumAccuracy, checkMode, blockOnEmptyOnlineResponse, disabledKinds, radii }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        maximumAccuracy = try container.decodeIfPresent(Double.self, forKey: .maximumAccuracy) ?? 15
        checkMode = try container.decodeIfPresent(RestrictedPlacesCheckMode.self, forKey: .checkMode) ?? .automatic
        blockOnEmptyOnlineResponse = try container.decodeIfPresent(Bool.self, forKey: .blockOnEmptyOnlineResponse) ?? false
        disabledKinds = try container.decodeIfPresent(Set<RestrictedPlaceKind>.self, forKey: .disabledKinds) ?? []
        radii = try container.decodeIfPresent([String: Double].self, forKey: .radii) ?? [:]
    }
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
        // Valid multipolygons can contain an outer island inside an inner
        // courtyard, followed by another hole in that island. Subtracting
        // every inner ring from the union of all outers erased those islands.
        // Count the containing shells/holes so each nested outer restores its
        // own protected territory. Disjoint site footprints remain a union.
        if innerRings.isEmpty {
            if outerRings.contains(where: contains) { return 0 }
        } else {
            let containingOuters = outerRings.reduce(0) { $0 + (contains($1) ? 1 : 0) }
            let containingInners = innerRings.reduce(0) { $0 + (contains($1) ? 1 : 0) }
            if containingOuters > containingInners { return 0 }
        }
        var nearest = Double.infinity
        if let point { let p = xy(point); nearest = hypot(p.x, p.y) }
        for line in lines + outerRings + innerRings {
            let points = line.map(xy)
            guard !points.isEmpty else { continue }
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
    private struct Member: Decodable {
        let type: String; let role: String; let geometry: [OSMCoordinate]?
        let lat: Double?; let lon: Double?
    }

    static func parse(_ data: Data) throws -> [RestrictedPlace] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        // Overpass can return HTTP 200 with a timeout remark and partial elements.
        guard response.remark == nil else { throw RestrictedPlacesError.incompleteResponse }
        // `out geom` has no geometry bbox: a selected object must contain its
        // full geometry even when the selection itself uses a bbox. Dropping
        // one malformed playground while accepting another distant object
        // made an incomplete response look like verified absence nearby.
        return try response.elements.compactMap(parseElement)
    }

    private static func parseElement(_ element: Element) throws -> RestrictedPlace? {
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
                if tags["type"] == "site" {
                    // Some campuses are collections of buildings/points rather
                    // than a perimeter. Use every supplied footprint; never
                    // invent an enclosing fence or fall back to a centre.
                    for member in members {
                        if member.type == "node", let lat = member.lat, let lon = member.lon {
                            let p = OSMCoordinate(lat: lat, lon: lon)
                            guard p.valid else { throw RestrictedPlacesError.invalidGeometry }
                            lines.append([p])
                        } else if member.type == "way", let g = member.geometry, g.count >= 2, g.allSatisfy(\.valid) {
                            if g.first == g.last { outer.append(g) } else { lines.append(g) }
                        } else { throw RestrictedPlacesError.invalidGeometry }
                    }
                    guard !lines.isEmpty || !outer.isEmpty else { throw RestrictedPlacesError.invalidGeometry }
                    return RestrictedPlace(id: "relation/\(element.id)", kind: kind,
                        name: tags["name:ru"] ?? tags["name"], point: nil, lines: lines, outerRings: outer, innerRings: [])
                }
                // `out geom` does not supply the geometry of nested relation
                // members. Never accept just the directly supplied ways as a
                // complete boundary when an outer/inner child is unresolved.
                guard !members.contains(where: {
                    $0.type == "relation" && ($0.role.isEmpty || $0.role == "outer" || $0.role == "inner")
                }) else { throw RestrictedPlacesError.invalidGeometry }
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
    let isEmptyOnlineResponse: Bool
    /// nil denotes a full offline dataset / a query containing every category.
    /// A filtered online answer cannot verify categories enabled afterwards.
    let queriedKinds: Set<RestrictedPlaceKind>?
    let hasTrustedProvenance: Bool
    var offlineBounds: OfflineRegionBounds? = nil
    var offlineCoverage: [OfflineRegionBounds]? = nil
    var index: RestrictedPlaceIndex? = nil
    init(center: CLLocation, radius: Double, fetchedAt: Date, places: [RestrictedPlace],
         offlineBounds: OfflineRegionBounds? = nil, offlineCoverage: [OfflineRegionBounds]? = nil,
         index: RestrictedPlaceIndex? = nil, isEmptyOnlineResponse: Bool = false,
         queriedKinds: Set<RestrictedPlaceKind>? = nil, hasTrustedProvenance: Bool = true) {
        self.center = center; self.radius = radius; self.fetchedAt = fetchedAt; self.places = places
        self.isEmptyOnlineResponse = isEmptyOnlineResponse
        self.queriedKinds = queriedKinds
        self.hasTrustedProvenance = hasTrustedProvenance
        self.offlineBounds = offlineBounds; self.offlineCoverage = offlineCoverage; self.index = index
    }
    func covers(_ location: CLLocation, settings: RestrictedPlaceSettings, now: Date) -> Bool {
        guard hasTrustedProvenance else { return false }
        if let queriedKinds,
           !Set(RestrictedPlaceKind.allCases.filter(settings.includes)).isSubset(of: queriedKinds) { return false }
        let age = now.timeIntervalSince(fetchedAt)
        if let offlineCoverage {
            return age >= 0 && age < 30 * 86400 && offlineCoverage.contains {
                $0.contains(location.coordinate, margin: settings.maximumRadius + location.horizontalAccuracy)
            }
        }
        if let bounds = offlineBounds {
            return age >= 0 && age < 30 * 86400 && bounds.contains(location.coordinate, margin: settings.maximumRadius + location.horizontalAccuracy)
        }
        return age >= 0 && age < 600 && center.distance(from: location) + settings.maximumRadius + location.horizontalAccuracy < radius
    }
}

struct CaptureZoneDecision: Equatable {
    let blocked: Bool
    let message: String
    let nearby: [RestrictedPlaceSummary]
    init(blocked: Bool, message: String, nearby: [RestrictedPlaceSummary] = []) {
        self.blocked = blocked
        self.message = message
        self.nearby = nearby
    }
    static let disabled = Self(blocked: false, message: "")
}

struct RestrictedPlaceSummary: Identifiable, Equatable {
    let id: String
    let kind: RestrictedPlaceKind
    let name: String?
    let distance: Double

    var title: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? kind.singular : trimmed
    }

    var displayTitle: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? kind.singular : "\(kind.singular): \(trimmed)"
    }

    var distanceText: String {
        if distance >= 1000 {
            let kilometres = floor(distance / 1000 * 10 + 0.5) / 10
            return String(format: "%.1f км", kilometres)
        }
        return "\(Int(distance.rounded())) м"
    }
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
        if snapshot.isEmptyOnlineResponse && settings.blockOnEmptyOnlineResponse {
            return .init(blocked: true, message: "OSM вернул пустой ответ. Включён запрет съёмки при неполных данных.")
        }
        let detailRadius = max(1000, settings.maximumRadius + location.horizontalAccuracy)
        let nearby = snapshot.index?.near(location, radius: detailRadius) ?? snapshot.places
        let candidates = nearby.filter { settings.includes($0.kind) }.compactMap { place -> (RestrictedPlace, Double)? in
            let distance = place.distance(from: location)
            return (place, distance)
        }.sorted { $0.1 < $1.1 }
        var nearestByKind: [RestrictedPlaceKind: RestrictedPlaceSummary] = [:]
        for (place, distance) in candidates where nearestByKind[place.kind] == nil {
            nearestByKind[place.kind] = RestrictedPlaceSummary(id: place.id, kind: place.kind,
                                                               name: place.name, distance: distance)
        }
        let summaries = nearestByKind.values.sorted { $0.distance < $1.distance }.prefix(3)
        let nearest = Array(summaries)
        let violations = candidates.compactMap { place, distance -> (RestrictedPlace, Double, Bool)? in
            let radius = settings.radius(for: place.kind)
            guard distance - location.horizontalAccuracy <= radius else { return nil }
            return (place, distance, distance > radius)
        }
        guard !violations.isEmpty else {
            return .init(blocked: false, message: "Запретных зон по данным OpenStreetMap рядом не найдено", nearby: nearest)
        }
        let reasons = violations.prefix(3).map { place, distance, uncertain in
            "\(place.kind.singular) — \(Int(distance.rounded())) м" + (uncertain ? " (с учётом погрешности GPS)" : "")
        }.joined(separator: "\n")
        return .init(blocked: true, message: reasons + (violations.count > 3 ? "\nИ ещё \(violations.count - 3) зон" : ""), nearby: nearest)
    }
}
