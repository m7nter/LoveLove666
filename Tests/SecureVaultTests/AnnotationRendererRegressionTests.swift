import XCTest
import UIKit
@testable import SecureVault

final class AnnotationRendererRegressionTests: XCTestCase {
    private let orientations: [UIImage.Orientation] = [
        .up, .down, .left, .right,
        .upMirrored, .downMirrored, .leftMirrored, .rightMirrored
    ]

    private func checkerboard(orientation: UIImage.Orientation, scale: CGFloat) throws -> UIImage {
        let size = CGSize(width: 240, height: 160)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let raw = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.red.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            UIColor.green.setFill()
            UIRectFill(CGRect(x: 120, y: 0, width: 120, height: 80))
            UIColor.blue.setFill()
            UIRectFill(CGRect(x: 0, y: 80, width: 120, height: 80))
            UIColor.yellow.setFill()
            UIRectFill(CGRect(x: 120, y: 80, width: 120, height: 80))
            UIColor.black.withAlphaComponent(0.7).setFill()
            for y in stride(from: 0, to: 160, by: 4) {
                for x in stride(from: 0, to: 240, by: 4) where (x / 4 + y / 4).isMultiple(of: 2) {
                    UIRectFill(CGRect(x: CGFloat(x), y: CGFloat(y), width: 4, height: 4))
                }
            }
        }
        return UIImage(cgImage: try XCTUnwrap(raw.cgImage), scale: scale, orientation: orientation)
    }

    private func pixels(_ image: UIImage, region: CGRect? = nil) throws -> Data {
        let source = try XCTUnwrap(image.cgImage)
        let cg: CGImage
        if let region = region { cg = try XCTUnwrap(source.cropping(to: region)) }
        else { cg = source }
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress,
                width: cg.width, height: cg.height, bitsPerComponent: 8,
                bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .none
            context.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        }
        return Data(bytes)
    }

    func testBlurLayerUsesDisplayedPhotoOrientationAndPixelDimensions() throws {
        for orientation in orientations {
            for scale in [CGFloat(1), CGFloat(2), CGFloat(3)] {
                let source = try checkerboard(orientation: orientation, scale: scale)
                // UIKit's draw path is also used by the source photo and saved
                // annotations; the blur must occupy that same coordinate space.
                let displayed = try XCTUnwrap(source.normalized())
                let actual = try XCTUnwrap(AnnotationRenderer.blurred(source))
                let reference = try XCTUnwrap(AnnotationRenderer.blurred(displayed))
                XCTAssertEqual(actual.imageOrientation, .up)
                XCTAssertEqual(actual.size, displayed.size)
                XCTAssertEqual(actual.scale, scale)
                XCTAssertEqual(actual.cgImage?.width, displayed.cgImage?.width)
                XCTAssertEqual(actual.cgImage?.height, displayed.cgImage?.height)
                XCTAssertEqual(try pixels(actual), try pixels(reference),
                               "Blur must preserve orientation \(orientation.rawValue), scale \(scale)")
            }
        }
    }

    func testBrushReachesTopAndBottomOfRotatedPhotoWithoutChangingUnpaintedPixels() throws {
        let stroke = DrawnShape(tool: .blur, start: CGPoint(x: 0.5, y: 0),
            end: CGPoint(x: 0.5, y: 1), color: .red,
            points: [CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1)], width: 0.3)
        for orientation in orientations {
            for scale in [CGFloat(1), CGFloat(2), CGFloat(3)] {
                let source = try checkerboard(orientation: orientation, scale: scale)
                let baseline = AnnotationRenderer.render(image: source, shapes: [])
                let marked = AnnotationRenderer.render(image: source, shapes: [stroke])
                let cg = try XCTUnwrap(baseline.cgImage)
                XCTAssertEqual(marked.size, source.size)
                XCTAssertEqual(marked.cgImage?.width, cg.width)
                XCTAssertEqual(marked.cgImage?.height, cg.height)
                // These samples lie in the bands that used to stay clear when
                // a landscape blur layer was aspect-fitted over a portrait photo.
                for y in [2, cg.height / 2, cg.height - 10] {
                    let painted = CGRect(x: CGFloat(cg.width / 2 - 4), y: CGFloat(y), width: 8, height: 8)
                    XCTAssertNotEqual(try pixels(marked, region: painted),
                                      try pixels(baseline, region: painted),
                                      "Brush must cover y=\(y), orientation \(orientation.rawValue), scale \(scale)")
                }
                let untouched = CGRect(x: 2, y: CGFloat(cg.height / 2), width: 8, height: 8)
                XCTAssertEqual(try pixels(marked, region: untouched), try pixels(baseline, region: untouched))
            }
        }
    }
}
