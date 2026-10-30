import SwiftUI
import CoreLocation
import MapKit
import MapLibre

/// A view of the camera's current verification, not a second OSM client.
struct RestrictedPlacesRadarView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var monitor = RestrictedPlacesMonitor.shared
    @ObservedObject private var location = LocationManager.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var selectedID: String?
    @State private var following = true
    @State private var recenter = 0
    @State private var mapUnavailable = false

    private var selected: RestrictedPlace? {
        monitor.radarPlaces.first { $0.id == selectedID } ?? monitor.radarPlaces.first
    }
    private var statusColor: Color {
        !monitor.radarIsVerified ? .orange : (monitor.decision.blocked ? .red : .green)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 23, weight: .semibold)).foregroundStyle(.orange)
                    .frame(width: 46, height: 46).background(.orange.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Радар").font(.title2.bold()).accessibilityIdentifier("radar.title")
                    Text("Территории рядом с вами").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .bold))
                        .frame(width: 42, height: 42).background(.white.opacity(0.09), in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("Закрыть радар").accessibilityIdentifier("radar.close")
            }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: monitor.radarIsVerified ? (monitor.decision.blocked ? "hand.raised.fill" : "checkmark.shield.fill") : "clock.badge.exclamationmark")
                    .foregroundStyle(statusColor).font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(monitor.radarIsVerified ? (monitor.decision.blocked ? "Съёмка заблокирована" : "Зоны проверены") : "Проверка не завершена")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(statusColor)
                        .accessibilityIdentifier("radar.status")
                    Text(monitor.decision.message.isEmpty ? "Включите контроль территорий в настройках." : monitor.decision.message)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(statusColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20).padding(.bottom, 14)

            ZStack(alignment: .topTrailing) {
                RadarStreetMap(places: monitor.radarPlaces, revision: monitor.radarRevision,
                    location: location.location, restrictions: settings.restrictedPlaces,
                    selectedID: selected?.id, following: $following, recenter: recenter,
                    mapUnavailable: $mapUnavailable, onSelect: { selectedID = $0 })
                    .accessibilityIdentifier("radar.map")
                Button {
                    following = true
                    recenter += 1
                } label: {
                    Image(systemName: following ? "location.fill" : "location")
                        .font(.system(size: 19, weight: .semibold)).foregroundStyle(following ? .orange : .white)
                        .frame(width: 46, height: 46).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15))
                }.padding(14).buttonStyle(.plain).accessibilityLabel("К моей позиции").accessibilityIdentifier("radar.recenter")
                if !RestrictedPlacesRadarGeometry.hasUsableCoordinate(location.location) {
                    VStack(spacing: 10) {
                        Image(systemName: "location.slash").font(.title)
                        Text("Ожидаем координаты").font(.headline)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black.opacity(0.7)).allowsHitTesting(false)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).frame(minHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 22)).padding(.horizontal, 12)

            if mapUnavailable {
                Label("Подложка карты недоступна. Данные зон показаны отдельно.", systemImage: "map")
                    .font(.caption2).foregroundStyle(.orange).padding(.horizontal, 20).padding(.top, 8)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(RestrictedPlaceKind.allCases.filter(settings.restrictedPlaces.includes)) { kind in
                        HStack(spacing: 6) {
                            Image(systemName: kind.radarSymbol)
                            Text(kind.singular)
                        }.font(.caption.weight(.medium)).foregroundStyle(Color(kind.radarColor))
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(Color(kind.radarColor).opacity(0.12), in: Capsule())
                    }
                }.padding(.horizontal, 20)
            }.padding(.top, 12).accessibilityIdentifier("radar.legend")

            if let selected, monitor.radarIsVerified {
                details(selected)
            } else {
                Text(monitor.radarIsVerified ? "В проверенной области объекты выбранных категорий не найдены." : "Актуальные зоны появятся после проверки вашей позиции.")
                    .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20).padding(.top, 12)
            }
            Text("Нажмите на объект. Расстояния и проверка относятся к вашей позиции.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 14)
        }.background(Color.black).foregroundStyle(.white).preferredColorScheme(.dark)
            .onChange(of: monitor.radarRevision) { _ in
                if !monitor.radarPlaces.contains(where: { $0.id == selectedID }) { selectedID = nil }
            }
    }

    private func details(_ place: RestrictedPlace) -> some View {
        let radius = settings.restrictedPlaces.radius(for: place.kind)
        let distance = location.location.map { place.distance(from: $0) }
        let summary = distance.map { RestrictedPlaceSummary(id: place.id, kind: place.kind, name: place.name, distance: $0) }
        return HStack(spacing: 12) {
            Image(systemName: place.kind.radarSymbol).font(.title3).foregroundStyle(Color(place.kind.radarColor))
                .frame(width: 42, height: 42).background(Color(place.kind.radarColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 4) {
                Text(summary?.title ?? place.kind.singular).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text("\(place.kind.singular) · запрет ближе \(Int(radius)) м").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(summary?.distanceText ?? "—").font(.system(size: 23, weight: .semibold, design: .rounded))
                .foregroundStyle((distance ?? .infinity) < radius ? .red : .white).monospacedDigit()
        }.padding(14).background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 18))
            .padding(.horizontal, 20).padding(.top, 12).accessibilityIdentifier("radar.details")
    }
}

private extension RestrictedPlaceKind {
    var radarSymbol: String {
        switch self {
        case .playground: return "figure.play"
        case .kindergarten: return "building.2.fill"
        case .school: return "graduationcap.fill"
        case .sports: return "sportscourt.fill"
        case .police: return "shield.lefthalf.filled"
        case .security: return "lock.shield.fill"
        case .administration, .government: return "building.columns.fill"
        case .court, .prosecutor: return "scalemass.fill"
        case .recruitment, .military: return "star.circle.fill"
        }
    }
    var radarColor: UIColor {
        switch self {
        case .playground: return .systemOrange
        case .kindergarten: return .systemPink
        case .school: return .systemPurple
        case .sports: return .systemTeal
        case .police: return .systemBlue
        case .security: return .systemRed
        case .administration, .government: return .systemIndigo
        case .court, .prosecutor: return .systemBrown
        case .recruitment, .military: return .systemRed
        }
    }
}

/// Projection-independent helpers are shared by the overlay and its regressions.
enum RestrictedPlacesRadarGeometry {
    static func hasUsableCoordinate(_ location: CLLocation?) -> Bool {
        guard let location else { return false }
        return CLLocationCoordinate2DIsValid(location.coordinate) && abs(location.coordinate.latitude) <= 85.05112878
    }
    static func bufferWidth(radius: Double, metersPerPoint: Double) -> CGFloat {
        guard radius.isFinite, radius > 0, metersPerPoint.isFinite, metersPerPoint > 0 else { return 0 }
        // A stroke is centred on its path: half the width extends outside it.
        return CGFloat(2 * radius / metersPerPoint)
    }
    static func circle(around center: OSMCoordinate, radius: Double, segments: Int = 64) -> [OSMCoordinate] {
        guard center.valid, radius.isFinite, radius > 0 else { return [] }
        let count = max(16, min(256, segments)), angle = radius / 6_371_000
        let latitude = center.lat * .pi / 180, longitude = center.lon * .pi / 180
        var result = (0..<count).map { index -> OSMCoordinate in
            let bearing = Double(index) / Double(count) * 2 * .pi
            let lat = asin(sin(latitude) * cos(angle) + cos(latitude) * sin(angle) * cos(bearing))
            let lon = longitude + atan2(sin(bearing) * sin(angle) * cos(latitude), cos(angle) - sin(latitude) * sin(lat))
            return .init(lat: lat * 180 / .pi, lon: (lon * 180 / .pi + 540).truncatingRemainder(dividingBy: 360) - 180)
        }
        result.append(result[0])
        return result
    }
    static func markerCoordinate(for place: RestrictedPlace) -> OSMCoordinate? {
        // For a mapped territory a marker labels its boundary, never an
        // invented centre whose radius could imply different safety geometry.
        place.outerRings.first?.first ?? place.lines.first?.first ?? place.point
    }
    static func isolatedPoints(for place: RestrictedPlace) -> [OSMCoordinate] {
        // Site relations may carry a node as a one-coordinate line. A path
        // containing only move(to:) has no stroke, but that node still has
        // the full protection radius in the capture policy.
        var points: [OSMCoordinate] = []
        for line in place.lines where line.count == 1 {
            if let point = line.first, point.valid, !points.contains(point) { points.append(point) }
        }
        if place.outerRings.isEmpty && place.innerRings.isEmpty && place.lines.isEmpty,
           let point = place.point, point.valid, !points.contains(point) { points.append(point) }
        return points
    }
}

private struct RadarStreetMap: UIViewRepresentable {
    let places: [RestrictedPlace]
    let revision: Int
    let location: CLLocation?
    let restrictions: RestrictedPlaceSettings
    let selectedID: String?
    @Binding var following: Bool
    let recenter: Int
    @Binding var mapUnavailable: Bool
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> MLNMapView {
        OpenStreetMapConfiguration.configure()
        let map = MLNMapView(frame: .zero, styleURL: OpenStreetMapConfiguration.styleURL)
        map.delegate = context.coordinator
        map.minimumZoomLevel = 8; map.maximumZoomLevel = 19
        map.isPitchEnabled = false; map.isRotateEnabled = false
        map.showsUserLocation = false // Reuse the camera's GPS, never a second CLLocationManager.
        map.showsLogoView = false; map.showsAttributionButton = true; map.showsScale = true
        map.backgroundColor = UIColor(white: 0.10, alpha: 1)
        let canvas = context.coordinator.canvas
        canvas.map = map; canvas.frame = map.bounds; canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.backgroundColor = .clear; canvas.isUserInteractionEnabled = false
        map.addSubview(canvas)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        // A single tap selects an object; double taps retain the SDK's zoom.
        // Waiting for the SDK's single-tap recognizer would swallow selection.
        for case let existing as UITapGestureRecognizer in map.gestureRecognizers ?? [] where existing.numberOfTapsRequired > 1 {
            tap.require(toFail: existing)
        }
        map.addGestureRecognizer(tap)
        context.coordinator.update(map)
        return map
    }
    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(map)
    }
    static func dismantleUIView(_ map: MLNMapView, coordinator: Coordinator) {
        map.delegate = nil
        coordinator.canvas.map = nil
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: RadarStreetMap
        let canvas = RadarMapCanvas()
        private var lastRevision: Int?
        private var lastSettings: RestrictedPlaceSettings?
        private var lastRecenter = -1
        private var hasCentered = false
        private var lastLatitude: Double?
        private var lastLongitude: Double?
        private var lastAccuracy: Double?
        private var lastSelection: String?
        init(_ parent: RadarStreetMap) { self.parent = parent }

        func update(_ map: MLNMapView) {
            let geometryChanged = lastRevision != parent.revision || lastSettings != parent.restrictions
            if geometryChanged {
                lastRevision = parent.revision; lastSettings = parent.restrictions
                canvas.features = parent.places.map { RadarMapFeature(place: $0, radius: parent.restrictions.radius(for: $0.kind)) }
            }
            canvas.selectedID = parent.selectedID
            canvas.location = parent.location
            let locationChanged = lastLatitude != parent.location?.coordinate.latitude
                || lastLongitude != parent.location?.coordinate.longitude || lastAccuracy != parent.location?.horizontalAccuracy
            let selectionChanged = lastSelection != parent.selectedID
            lastLatitude = parent.location?.coordinate.latitude; lastLongitude = parent.location?.coordinate.longitude
            lastAccuracy = parent.location?.horizontalAccuracy; lastSelection = parent.selectedID
            let requestedCenter = lastRecenter != parent.recenter
            lastRecenter = parent.recenter
            if RestrictedPlacesRadarGeometry.hasUsableCoordinate(parent.location), let location = parent.location,
               !hasCentered || requestedCenter || (parent.following && CLLocation(latitude: map.centerCoordinate.latitude, longitude: map.centerCoordinate.longitude).distance(from: location) > 1) {
                map.setCenter(location.coordinate, zoomLevel: hasCentered ? map.zoomLevel : 15.5, animated: hasCentered && requestedCenter)
                hasCentered = true
            }
            if geometryChanged || locationChanged || selectionChanged || requestedCenter { canvas.setNeedsDisplay() }
        }
        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            if let id = canvas.place(at: gesture.location(in: canvas)) { parent.onSelect(id) }
        }
        func mapView(_ mapView: MLNMapView, shouldChangeFrom oldCamera: MLNMapCamera, to newCamera: MLNMapCamera) -> Bool {
            // This delegate is invoked for user gestures only. A programmatic
            // recenter/GPS update must not turn following off again.
            if parent.following { DispatchQueue.main.async { [weak self] in self?.parent.following = false } }
            return true
        }
        func mapViewRegionIsChanging(_ mapView: MLNMapView) { canvas.setNeedsDisplay() }
        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) { canvas.setNeedsDisplay() }
        func mapViewDidFinishLoadingMap(_ mapView: MLNMapView) {
            DispatchQueue.main.async { [weak self] in self?.parent.mapUnavailable = false }
            canvas.setNeedsDisplay()
        }
        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            DispatchQueue.main.async { [weak self] in self?.parent.mapUnavailable = true }
        }
    }
}

private struct RadarMapFeature {
    let place: RestrictedPlace
    let radius: Double
    let pointBuffers: [[OSMCoordinate]]
    init(place: RestrictedPlace, radius: Double) {
        self.place = place; self.radius = radius
        pointBuffers = RestrictedPlacesRadarGeometry.isolatedPoints(for: place)
            .map { RestrictedPlacesRadarGeometry.circle(around: $0, radius: radius) }
    }
}

/// The map has pitch/rotation disabled. Screen-point widths use MapLibre's
/// actual zoom/latitude scale, so a 65 m boundary buffer remains 65 m on zoom.
/// Every mapped boundary is used, including courtyard holes and outer islands.
private final class RadarMapCanvas: UIView {
    weak var map: MLNMapView?
    var features: [RadarMapFeature] = []
    var selectedID: String?
    var location: CLLocation?
    private var markerHits: [(String, CGPoint)] = []
    private var areaHits: [(id: String, territory: CGPath, pointBuffer: CGPath, boundaryBuffer: CGPath)] = []

    override func draw(_ rect: CGRect) {
        guard let map, let context = UIGraphicsGetCurrentContext(), bounds.width > 0, bounds.height > 0 else { return }
        markerHits.removeAll(keepingCapacity: true); areaHits.removeAll(keepingCapacity: true)
        for feature in features {
            let place = feature.place, color = place.kind.radarColor
            // Use the latitude of the visible area. A large military/admin
            // contour may start hundreds of kilometres beyond this viewport.
            let latitude = map.centerCoordinate.latitude
            let width = RestrictedPlacesRadarGeometry.bufferWidth(radius: feature.radius, metersPerPoint: map.metersPerPoint(atLatitude: latitude))
            let territory = path(place.outerRings + place.innerRings, close: true, map: map)
            let boundary = path(place.lines + place.outerRings + place.innerRings, close: false, map: map)
            let pointBuffer = path(feature.pointBuffers, close: true, map: map)
            let expandedBounds = boundary.boundingBoxOfPath.insetBy(dx: -width / 2 - 24, dy: -width / 2 - 24)
            let visible = expandedBounds.intersects(bounds) || territory.boundingBoxOfPath.intersects(bounds) || pointBuffer.boundingBoxOfPath.intersects(bounds)
            guard visible else { continue }
            context.saveGState()
            context.setLineJoin(.round); context.setLineCap(.round)
            context.setFillColor(color.withAlphaComponent(0.16).cgColor)
            context.addPath(territory); context.drawPath(using: .eoFill)
            context.addPath(pointBuffer); context.drawPath(using: .fill)
            context.setLineWidth(width); context.setStrokeColor(color.withAlphaComponent(0.15).cgColor)
            context.addPath(boundary); context.strokePath()
            context.setLineWidth(place.id == selectedID ? 2.5 : 1.5)
            context.setStrokeColor(color.withAlphaComponent(0.85).cgColor)
            context.addPath(boundary); context.strokePath()
            context.addPath(pointBuffer); context.strokePath()
            context.restoreGState()
            // Screen hit geometry follows the same real paths as rendering.
            let hit = boundary.copy(strokingWithWidth: max(18, width), lineCap: .round, lineJoin: .round, miterLimit: 1)
            areaHits.append((place.id, territory, pointBuffer, hit))
        }
        // Markers go above every translucent buffer, and GPS above markers.
        for feature in features {
            guard let coordinate = RestrictedPlacesRadarGeometry.markerCoordinate(for: feature.place) else { continue }
            let point = map.convert(coordinate.coordinate, toPointTo: self)
            guard point.x.isFinite, point.y.isFinite, bounds.insetBy(dx: -24, dy: -24).contains(point) else { continue }
            drawMarker(feature.place, at: point, context: context)
            markerHits.append((feature.place.id, point))
        }
        if RestrictedPlacesRadarGeometry.hasUsableCoordinate(location), let location {
            let point = map.convert(location.coordinate, toPointTo: self)
            guard point.x.isFinite, point.y.isFinite else { return }
            let scale = map.metersPerPoint(atLatitude: location.coordinate.latitude)
            let accuracy = scale > 0 ? CGFloat(max(0, min(500, location.horizontalAccuracy)) / scale) : 0
            context.setFillColor(UIColor.systemBlue.withAlphaComponent(0.10).cgColor)
            context.fillEllipse(in: CGRect(x: point.x - accuracy, y: point.y - accuracy, width: accuracy * 2, height: accuracy * 2))
            context.setFillColor(UIColor.systemBlue.cgColor); context.setStrokeColor(UIColor.white.cgColor); context.setLineWidth(3)
            context.addEllipse(in: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)); context.drawPath(using: .fillStroke)
        }
    }
    private func path(_ rings: [[OSMCoordinate]], close: Bool, map: MLNMapView) -> CGPath {
        let path = CGMutablePath()
        for ring in rings {
            var started = false
            for coordinate in ring where coordinate.valid {
                let point = map.convert(coordinate.coordinate, toPointTo: self)
                guard point.x.isFinite, point.y.isFinite else { continue }
                if started { path.addLine(to: point) } else { path.move(to: point); started = true }
            }
            if started && close { path.closeSubpath() }
        }
        return path
    }
    private func drawMarker(_ place: RestrictedPlace, at point: CGPoint, context: CGContext) {
        let selected = place.id == selectedID, radius: CGFloat = selected ? 18 : 15
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 2), blur: 5, color: UIColor.black.withAlphaComponent(0.3).cgColor)
        context.setFillColor(place.kind.radarColor.cgColor); context.setStrokeColor(UIColor.white.cgColor); context.setLineWidth(selected ? 3 : 2)
        context.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)); context.drawPath(using: .fillStroke)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        let icon = UIImage(systemName: place.kind.radarSymbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        icon?.draw(in: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16))
        context.restoreGState()
    }
    func place(at point: CGPoint) -> String? {
        if let marker = markerHits.min(by: { hypot($0.1.x - point.x, $0.1.y - point.y) < hypot($1.1.x - point.x, $1.1.y - point.y) }),
           hypot(marker.1.x - point.x, marker.1.y - point.y) <= 28 { return marker.0 }
        return areaHits.reversed().first {
            $0.territory.contains(point, using: .evenOdd) || $0.pointBuffer.contains(point) || $0.boundaryBuffer.contains(point)
        }?.id
    }
}
