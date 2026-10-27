import XCTest
import UIKit
@testable import SecureVault

@MainActor final class CameraAimRegressionTests: XCTestCase {
    private func image(_ size: CGSize, scale: CGFloat = 1) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.black.setFill(); UIRectFill(CGRect(origin: .zero, size: size))
        }
    }

    private func pixel(_ image: UIImage, x: Int, y: Int) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return rgba
    }

    func testPreviewAimAlwaysUsesActualPreviewCentreAcrossSizes() throws {
        for size in [CGSize(width: 393, height: 852), CGSize(width: 430, height: 932), CGSize(width: 320, height: 568)] {
            let view = PreviewView(frame: CGRect(origin: .zero, size: size))
            view.setCrosshair(visible: true, color: "red")
            view.layoutIfNeeded()
            let aim = try XCTUnwrap(view.layer.sublayers?.first { $0.name == "camera.aim" } as? CAShapeLayer)
            let bounds = try XCTUnwrap(aim.path).boundingBoxOfPath
            XCTAssertEqual(bounds.midX, size.width / 2, accuracy: 0.01)
            XCTAssertEqual(bounds.midY, size.height / 2, accuracy: 0.01)
            XCTAssertFalse(aim.isHidden)
            view.setCrosshair(visible: false, color: "red")
            XCTAssertTrue(aim.isHidden)
        }
    }

    func testSavedAimStaysAtOriginalPhotoCentreWithAndWithoutFooter() throws {
        let store = SettingsStore.shared
        let oldAim = store.crosshairOnPhoto, oldColor = store.crosshairColor, oldAvatar = store.avatarImage
        defer { store.crosshairOnPhoto = oldAim; store.crosshairColor = oldColor; store.avatarImage = oldAvatar }
        store.crosshairOnPhoto = true; store.crosshairColor = "red"; store.avatarImage = nil
        for size in [CGSize(width: 600, height: 800), CGSize(width: 800, height: 600)] {
            for scale in [CGFloat(1), CGFloat(2)] {
                let original = image(size, scale: scale)
                let labels: [String?] = [nil, "Подпись под исходной фотографией"]
                for label in labels {
                    let marked = WatermarkRenderer.apply(to: original, location: nil, heading: nil, labelText: label)
                    XCTAssertEqual(marked.cgImage?.width, original.cgImage?.width)
                    if label != nil { XCTAssertGreaterThan(marked.size.height, original.size.height) }
                    else { XCTAssertEqual(marked.size.height, original.size.height) }
                    let center = try pixel(marked, x: Int(size.width * scale / 2), y: Int(size.height * scale / 2))
                    XCTAssertGreaterThan(center[0], 200)
                    XCTAssertLessThan(center[1], 50)
                    XCTAssertLessThan(center[2], 50)
                    // The old code placed the aim below the optical centre,
                    // shifted by half of the coordinate strip height.
                    let below = try pixel(marked, x: Int(size.width * scale / 2), y: Int((size.height / 2 + 60) * scale))
                    XCTAssertLessThan(below[0], 50)
                }
            }
        }
    }
}
