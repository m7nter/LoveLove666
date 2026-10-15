import SwiftUI
import MapKit

final class OpenStreetTileOverlay: MKTileOverlay {
    private static let tileCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 160 * 1024 * 1024, diskPath: "OpenStreetMapTiles")
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = tileCache
        config.requestCachePolicy = .useProtocolCachePolicy
        config.httpMaximumConnectionsPerHost = 4
        config.httpAdditionalHeaders = ["User-Agent": "Calculator/1.2.0 (com.securevault.app)"]
        return URLSession(configuration: config)
    }()

    init() {
        super.init(urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
        canReplaceMapContent = true
        minimumZ = 0; maximumZ = 19
        tileSize = CGSize(width: 256, height: 256)
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let request = URLRequest(url: url(forTilePath: path), cachePolicy: .useProtocolCachePolicy, timeoutInterval: 20)
        Self.session.dataTask(with: request) { data, response, error in
            guard let response = response as? HTTPURLResponse, response.statusCode == 200, let data else {
                result(nil, error ?? URLError(.badServerResponse)); return
            }
            // URLSession honors HTTP expiry/ETag; use the OSM-required seven-day
            // fallback only if the server did not provide any caching lifetime.
            if response.value(forHTTPHeaderField: "Cache-Control") == nil && response.value(forHTTPHeaderField: "Expires") == nil {
                var headers = response.allHeaderFields.reduce(into: [String: String]()) { $0[String(describing: $1.key)] = String(describing: $1.value) }
                headers["Cache-Control"] = "public, max-age=604800"
                if let url = response.url, let cachedResponse = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) {
                    Self.tileCache.storeCachedResponse(CachedURLResponse(response: cachedResponse, data: data), for: request)
                }
            }
            result(data, nil)
        }.resume()
    }
}

private final class PhotoMapAnnotation: NSObject, MKAnnotation {
    let pin: PhotoPin
    var coordinate: CLLocationCoordinate2D { pin.coordinate }
    init(_ pin: PhotoPin) { self.pin = pin }
}

struct OpenStreetPhotoMap: UIViewRepresentable {
    let pins: [PhotoPin]
    @Binding var region: MKCoordinateRegion
    let clusters: Bool
    let onSelect: (PhotoPin) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.delegate = context.coordinator
        view.isPitchEnabled = false
        view.pointOfInterestFilter = .excludingAll
        view.showsCompass = false; view.showsScale = true
        view.mapType = .standard
        view.addOverlay(OpenStreetTileOverlay(), level: .aboveLabels)
        view.setCameraZoomRange(MKMapView.CameraZoomRange(minCenterCoordinateDistance: 150, maxCenterCoordinateDistance: 30_000_000), animated: false)
        view.setRegion(region, animated: false)
        return view
    }

    func updateUIView(_ view: MKMapView, context: Context) {
        context.coordinator.parent = self
        let identifiers = pins.map { $0.url.path }
        if context.coordinator.identifiers != identifiers || context.coordinator.clusters != clusters {
            context.coordinator.identifiers = identifiers; context.coordinator.clusters = clusters
            view.removeAnnotations(view.annotations)
            view.addAnnotations(pins.map(PhotoMapAnnotation.init))
        }
        if !context.coordinator.isSameRegion(view.region, region) { view.setRegion(region, animated: true) }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: OpenStreetPhotoMap
        var identifiers: [String] = []
        var clusters = true
        init(_ parent: OpenStreetPhotoMap) { self.parent = parent }
        func isSameRegion(_ a: MKCoordinateRegion, _ b: MKCoordinateRegion) -> Bool {
            abs(a.center.latitude - b.center.latitude) < 0.000001 && abs(a.center.longitude - b.center.longitude) < 0.000001 && abs(a.span.latitudeDelta - b.span.latitudeDelta) < 0.000001
        }
        func mapView(_ view: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = view.region
            DispatchQueue.main.async { [weak self] in self?.parent.region = region }
        }
        func mapView(_ view: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tiles) }
            return MKOverlayRenderer(overlay: overlay)
        }
        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKClusterAnnotation {
                let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: nil)
                view.markerTintColor = .systemOrange
                view.glyphText = String((annotation as! MKClusterAnnotation).memberAnnotations.count)
                return view
            }
            guard let photo = annotation as? PhotoMapAnnotation else { return nil }
            let view = MKAnnotationView(annotation: annotation, reuseIdentifier: nil)
            view.clusteringIdentifier = parent.clusters ? "photos" : nil
            view.displayPriority = .defaultHigh
            view.centerOffset = CGPoint(x: 0, y: -24)
            let image = FileStorageManager.shared.loadThumbnail(at: photo.pin.url)
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48))
            view.image = renderer.image { _ in
                let rect = CGRect(x: 2, y: 2, width: 44, height: 44)
                UIColor.black.setFill(); UIBezierPath(roundedRect: rect, cornerRadius: 8).fill()
                if let image {
                    let scale = min(40 / image.size.width, 40 / image.size.height)
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    image.draw(in: CGRect(x: 24 - size.width / 2, y: 24 - size.height / 2, width: size.width, height: size.height))
                }
                UIColor.systemOrange.setStroke()
                let border = UIBezierPath(roundedRect: rect, cornerRadius: 8); border.lineWidth = 2; border.stroke()
            }
            return view
        }
        func mapView(_ map: MKMapView, didSelect view: MKAnnotationView) {
            if let cluster = view.annotation as? MKClusterAnnotation {
                map.showAnnotations(cluster.memberAnnotations, animated: true)
            } else if let photo = view.annotation as? PhotoMapAnnotation { parent.onSelect(photo.pin) }
            if let annotation = view.annotation { map.deselectAnnotation(annotation, animated: false) }
        }
    }
}
