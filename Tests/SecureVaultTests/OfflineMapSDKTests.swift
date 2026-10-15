import XCTest
import UIKit
import MapLibre

/// Exercise MapLibre's real offline database with deterministic HTTP fixtures,
/// then deny all HTTP and load the same map style from the saved pack.
final class OfflineMapSDKTests: XCTestCase {
    @MainActor func testNativePackLoadsAfterNetworkIsDisabled() throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineMapHTTPFixture.self]
        MLNNetworkConfiguration.sharedManager.sessionConfiguration = config
        OfflineMapHTTPFixture.setOffline(false)
        let url = URL(string: "https://offline-test.invalid/style.json")!
        let region = MLNTilePyramidOfflineRegion(styleURL: url,
            bounds: MLNCoordinateBounds(sw: .init(latitude: -0.1, longitude: -0.1), ne: .init(latitude: 0.1, longitude: 0.1)), fromZoomLevel: 0, toZoomLevel: 0)
        let context = Data("offline-sdk-fixture".utf8)
        let downloaded = expectation(description: "All map resources downloaded")
        var fulfilled = false
        let observer = NotificationCenter.default.addObserver(forName: .init("MLNOfflinePackProgressChanged"), object: nil, queue: .main) { note in
            guard let pack = note.object as? MLNOfflinePack, pack.context == context, pack.state == .complete, !fulfilled else { return }
            fulfilled = true; downloaded.fulfill()
        }
        var savedPack: MLNOfflinePack?
        MLNOfflineStorage.shared.addPack(for: region, withContext: context) { pack, error in
            XCTAssertNil(error); savedPack = pack; pack?.resume()
        }
        wait(for: [downloaded], timeout: 20)
        NotificationCenter.default.removeObserver(observer)
        let pack = try XCTUnwrap(savedPack)
        XCTAssertEqual(pack.state, .complete)
        XCTAssertGreaterThan(pack.progress.countOfTilesCompleted, 0)
        OfflineMapHTTPFixture.setOffline(true)
        let styleLoaded = expectation(description: "Saved map style loads with HTTP disabled")
        let delegate = OfflineStyleDelegate { styleLoaded.fulfill() }
        let map = MLNMapView(frame: CGRect(x: 0, y: 0, width: 300, height: 300), styleURL: url)
        map.delegate = delegate
        map.setCenter(.init(latitude: 0, longitude: 0), zoomLevel: 0, animated: false)
        wait(for: [styleLoaded], timeout: 10)
        XCTAssertNotNil(map.style)
        map.delegate = nil
        let removed = expectation(description: "Remove fixture pack")
        MLNOfflineStorage.shared.removePack(pack) { error in XCTAssertNil(error); removed.fulfill() }
        wait(for: [removed], timeout: 10)
        OfflineMapHTTPFixture.setOffline(false)
    }
}

private final class OfflineStyleDelegate: NSObject, MLNMapViewDelegate {
    private var completed = false
    let onLoad: () -> Void
    init(_ onLoad: @escaping () -> Void) { self.onLoad = onLoad }
    func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
        if !completed { completed = true; onLoad() }
    }
}

private final class OfflineMapHTTPFixture: URLProtocol {
    private static let lock = NSLock()
    private static var offline = false
    static func setOffline(_ value: Bool) { lock.lock(); offline = value; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "offline-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let offline = Self.offline; Self.lock.unlock()
        if offline { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let url = request.url!
        let data: Data
        if url.path == "/style.json" {
            data = Data("""
            {"version":8,"sources":{"test":{"type":"raster","tiles":["https://offline-test.invalid/{z}/{x}/{y}.png"],"tileSize":256,"minzoom":0,"maxzoom":0}},"layers":[{"id":"test","type":"raster","source":"test"}]}
            """.utf8)
        } else {
            // A valid 1x1 PNG tile, no network service is involved.
            data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aJ1kAAAAASUVORK5CYII=")!
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Cache-Control":"public, max-age=31536000"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
