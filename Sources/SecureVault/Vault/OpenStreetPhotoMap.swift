import SwiftUI
import MapKit
import MapLibre

private final class OSMPhotoAnnotation: MLNPointAnnotation {
    let pins: [PhotoPin]
    init(_ pins: [PhotoPin]) {
        self.pins = pins
        super.init()
        coordinate = CLLocationCoordinate2D(latitude: pins.map { $0.coordinate.latitude }.reduce(0, +) / Double(pins.count),
                                           longitude: pins.map { $0.coordinate.longitude }.reduce(0, +) / Double(pins.count))
    }
    required init?(coder: NSCoder) { fatalError("Annotations are created from photo metadata") }
}

struct OpenStreetPhotoMap: UIViewRepresentable {
    let pins: [PhotoPin]
    @Binding var region: MKCoordinateRegion
    let clusters: Bool
    let onSelect: (PhotoPin) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> MLNMapView {
        OpenStreetMapConfiguration.configure()
        let view = MLNMapView(frame: .zero, styleURL: OpenStreetMapConfiguration.styleURL)
        view.delegate = context.coordinator
        view.minimumZoomLevel = 1; view.maximumZoomLevel = 19
        view.isPitchEnabled = false; view.isRotateEnabled = false
        view.showsLogoView = false
        view.showsAttributionButton = true
        view.setCenter(region.center, zoomLevel: 11, animated: false)
        context.coordinator.lastCenter = region.center
        return view
    }
    func updateUIView(_ view: MLNMapView, context: Context) {
        context.coordinator.parent = self
        let center = context.coordinator.lastCenter
        if abs(center.latitude - region.center.latitude) > 0.00001 || abs(center.longitude - region.center.longitude) > 0.00001 {
            view.setCenter(region.center, animated: true)
            context.coordinator.lastCenter = region.center
        }
        context.coordinator.updatePins(view)
    }
    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: OpenStreetPhotoMap
        var lastCenter = CLLocationCoordinate2D()
        private var key = ""
        init(_ parent: OpenStreetPhotoMap) { self.parent = parent }
        func updatePins(_ map: MLNMapView) {
            let zoom = Int(floor(map.zoomLevel))
            let newKey = "\(zoom)/\(parent.clusters)/" + parent.pins.map { $0.url.path }.joined(separator: "|")
            guard key != newKey else { return }; key = newKey
            var groups: [[PhotoPin]]
            if parent.clusters && parent.pins.count > 1 {
                let grid = 360 / pow(2.0, Double(zoom)) / 10
                let buckets = Dictionary(grouping: parent.pins) { pin in
                    "\(Int(floor(pin.coordinate.latitude / grid)))_\(Int(floor(pin.coordinate.longitude / grid)))"
                }
                groups = Array(buckets.values)
            } else { groups = parent.pins.map { [$0] } }
            if let annotations = map.annotations { map.removeAnnotations(annotations) }
            map.addAnnotations(groups.map(OSMPhotoAnnotation.init))
        }
        func mapView(_ map: MLNMapView, regionDidChangeAnimated animated: Bool) {
            lastCenter = map.centerCoordinate
            updatePins(map)
            let center = map.centerCoordinate, bounds = map.visibleCoordinateBounds
            let updated = MKCoordinateRegion(center: center, span: .init(latitudeDelta: abs(bounds.ne.latitude - bounds.sw.latitude),
                                                                        longitudeDelta: abs(bounds.ne.longitude - bounds.sw.longitude)))
            DispatchQueue.main.async { [weak self] in self?.parent.region = updated }
        }
        func mapView(_ map: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            guard let photo = annotation as? OSMPhotoAnnotation else { return nil }
            let view = MLNAnnotationView(reuseIdentifier: nil)
            view.frame = CGRect(x: 0, y: 0, width: 48, height: 48)
            view.backgroundColor = photo.pins.count > 1 ? .systemOrange : .black
            view.layer.cornerRadius = photo.pins.count > 1 ? 24 : 8
            view.layer.borderWidth = 2; view.layer.borderColor = UIColor.systemOrange.cgColor
            view.clipsToBounds = true
            if photo.pins.count > 1 {
                let label = UILabel(frame: view.bounds)
                label.text = String(photo.pins.count); label.textColor = .white; label.textAlignment = .center
                label.font = .systemFont(ofSize: 16, weight: .bold); view.addSubview(label)
            } else if let pin = photo.pins.first {
                let image = UIImageView(frame: view.bounds.insetBy(dx: 2, dy: 2))
                image.image = FileStorageManager.shared.loadThumbnail(at: pin.url)
                image.contentMode = .scaleAspectFit; view.addSubview(image)
            }
            return view
        }
        func mapView(_ map: MLNMapView, didSelect annotation: MLNAnnotation) {
            guard let photo = annotation as? OSMPhotoAnnotation else { return }
            if photo.pins.count > 1 { map.setCenter(photo.coordinate, zoomLevel: min(19, map.zoomLevel + 2), animated: true) }
            else if let pin = photo.pins.first { parent.onSelect(pin) }
            map.deselectAnnotation(annotation, animated: false)
        }
    }
}
