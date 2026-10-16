import UIKit
import CoreLocation

struct WatermarkRenderer {
    static func apply(to image: UIImage,
                      location: CLLocation?,
                      heading: CLHeading?,
                      labelText: String? = nil) -> UIImage {

        guard let normalized = image.normalizedPreservingPixelAspect() else { return image }
        let size = normalized.size
        let renderer = UIGraphicsImageRenderer(size: size)
        let result = renderer.image { _ in
            normalized.draw(at: .zero)

            let padding: CGFloat = size.width * 0.03
            let font = UIFont.monospacedSystemFont(
                ofSize: max(size.width * 0.028, 16), weight: .semibold)
            let smallFont = UIFont.monospacedSystemFont(
                ofSize: max(size.width * 0.022, 12), weight: .regular)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white
            ]
            let smallAttrs: [NSAttributedString.Key: Any] = [
                .font: smallFont,
                .foregroundColor: UIColor.white
            ]
            let lineHeight = font.lineHeight + 4
            let smallLineHeight = smallFont.lineHeight + 2

            // ── ВЕРХНЯЯ ПОЛОСА (2 строки если есть азимут) ──
            var topText = "LAT: N/A   LON: N/A"
            var accuracyText = ""
            var azmText = ""

            if let loc = location {
                topText = String(format: "%.6f,  %.6f",
                                 loc.coordinate.latitude,
                                 loc.coordinate.longitude)
                if loc.horizontalAccuracy > 0 {
                    accuracyText = "±\(Int(loc.horizontalAccuracy)) m"
                }
            }

            if let hdg = heading {
                let dir = LocationManager.shared.compassDirection(from: hdg.magneticHeading)
                azmText = String(format: "AZM: %d°  %@", Int(hdg.magneticHeading), dir)
            }

            let hasAzm = !azmText.isEmpty
            let topBarH = hasAzm
                ? lineHeight + smallLineHeight + padding * 2 + 4
                : lineHeight + padding * 2

            UIColor.black.withAlphaComponent(0.55).setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: size.width, height: topBarH))

            // Иконка + координаты
            let pinConfig = UIImage.SymbolConfiguration(pointSize: max(size.width * 0.025, 14))
            if let pinImg = UIImage(systemName: "mappin", withConfiguration: pinConfig)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                let iconSize = pinImg.size
                let iconY = padding + (lineHeight - iconSize.height) / 2
                pinImg.draw(at: CGPoint(x: padding, y: iconY))
                let coordRect = CGRect(
                    x: padding + iconSize.width + 6,
                    y: padding,
                    width: size.width * 0.65,
                    height: lineHeight)
                (topText as NSString).draw(in: coordRect, withAttributes: attrs)
            }

            // Точность + точка
            if !accuracyText.isEmpty {
                let dotSize: CGFloat = max(size.width * 0.018, 12)
                let dotX = size.width - dotSize - padding / 2
                let dotY = padding + (lineHeight - dotSize) / 2
                let isAccurate = location?.horizontalAccuracy ?? 999 < 15
                (isAccurate ? UIColor.green : UIColor.yellow).setFill()
                UIBezierPath(ovalIn: CGRect(x: dotX, y: dotY,
                                            width: dotSize, height: dotSize)).fill()
                let accSize = (accuracyText as NSString).size(withAttributes: smallAttrs)
                let accRect = CGRect(x: dotX - accSize.width - 8,
                                     y: padding + (lineHeight - smallLineHeight) / 2,
                                     width: accSize.width,
                                     height: smallLineHeight)
                (accuracyText as NSString).draw(in: accRect, withAttributes: smallAttrs)
            }

            // Азимут — вторая строка
            if hasAzm {
                // Иконка компаса
                let compassConfig = UIImage.SymbolConfiguration(pointSize: max(size.width * 0.02, 12))
                if let compassImg = UIImage(systemName: "location.north.fill",
                                           withConfiguration: compassConfig)?
                    .withTintColor(.orange, renderingMode: .alwaysOriginal) {
                    let iconSize = compassImg.size
                    let azmY = padding + lineHeight + 4
                    let iconY = azmY + (smallLineHeight - iconSize.height) / 2
                    compassImg.draw(at: CGPoint(x: padding, y: iconY))
                    let azmRect = CGRect(
                        x: padding + iconSize.width + 6,
                        y: azmY,
                        width: size.width * 0.5,
                        height: smallLineHeight)
                    (azmText as NSString).draw(in: azmRect, withAttributes: smallAttrs)
                }
            }

            // ── НИЖНЯЯ ЧАСТЬ ──
            let avatarImg = SettingsStore.shared.avatarImage
            let hasLabel = !(labelText ?? "").isEmpty
            let avatarSize: CGFloat = size.width * 0.22
            var actualBottomBarH: CGFloat = 0

            if hasLabel || avatarImg != nil {
                let bottomBarH = avatarSize + padding * 2
                actualBottomBarH = bottomBarH
                let bottomY = size.height - bottomBarH

                UIColor.black.withAlphaComponent(0.55).setFill()
                UIRectFill(CGRect(x: 0, y: bottomY, width: size.width, height: bottomBarH))

                if let label = labelText, !label.isEmpty {
                    let labelFont = UIFont.systemFont(ofSize: max(size.width * 0.03, 18), weight: .bold)
                    let labelAttrs: [NSAttributedString.Key: Any] = [
                        .font: labelFont,
                        .foregroundColor: UIColor.white
                    ]
                    let labelRect = CGRect(
                        x: padding, y: bottomY + padding,
                        width: size.width - avatarSize - padding * 3,
                        height: bottomBarH - padding * 2)
                    (label as NSString).draw(in: labelRect, withAttributes: labelAttrs)
                }

                if let avatar = avatarImg {
                    let avatarX = size.width - avatarSize - padding
                    let avatarY = size.height - avatarSize - padding
                    let avatarRect = CGRect(x: avatarX, y: avatarY,
                                           width: avatarSize, height: avatarSize)
                    let ctx = UIGraphicsGetCurrentContext()!
                    ctx.saveGState()
                    UIBezierPath(roundedRect: avatarRect,
                                 cornerRadius: avatarSize * 0.1).addClip()
                    avatar.draw(in: avatarRect)
                    ctx.restoreGState()
                }
            }

            // ── ПЕРЕКРЕСТИЕ НА ФОТО ──
            if SettingsStore.shared.crosshairOnPhoto {
                let cx = size.width / 2
                let cy = topBarH + (size.height - topBarH - actualBottomBarH) / 2
                let lineLen = size.width * 0.04
                let lineW: CGFloat = max(size.width * 0.004, 2)

                let crossColor: UIColor
                switch SettingsStore.shared.crosshairColor {
                case "red": crossColor = .red
                case "green": crossColor = .green
                case "yellow": crossColor = .yellow
                default: crossColor = .white
                }

                let ctx = UIGraphicsGetCurrentContext()!
                ctx.saveGState()
                ctx.setStrokeColor(crossColor.cgColor)
                ctx.setLineWidth(lineW)
                ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: cx - lineLen, y: cy))
                ctx.addLine(to: CGPoint(x: cx + lineLen, y: cy))
                ctx.strokePath()
                ctx.move(to: CGPoint(x: cx, y: cy - lineLen))
                ctx.addLine(to: CGPoint(x: cx, y: cy + lineLen))
                ctx.strokePath()
                ctx.restoreGState()
            }
        }
        return result
    }
}

extension UIImage {
    func normalizedPreservingPixelAspect() -> UIImage? {
        guard let cgImage else { return normalized() }
        let scale = max(scale, 1)
        let rawSize = CGSize(width: CGFloat(cgImage.width) / scale,
                             height: CGFloat(cgImage.height) / scale)
        let swapsAxes: Bool
        switch imageOrientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            swapsAxes = true
        default:
            swapsAxes = false
        }
        let targetSize = swapsAxes
            ? CGSize(width: rawSize.height, height: rawSize.width)
            : rawSize
        guard targetSize.width > 0, targetSize.height > 0 else { return nil }
        if imageOrientation == .up, abs(size.width / max(size.height, 1) - targetSize.width / targetSize.height) < 0.001 {
            return self
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            let sourceAspect = size.width / max(size.height, 1)
            let containerAspect = targetSize.width / max(targetSize.height, 1)
            let fit: CGRect
            if sourceAspect > containerAspect {
                let height = targetSize.width / sourceAspect
                fit = CGRect(x: 0, y: (targetSize.height - height) / 2,
                             width: targetSize.width, height: height)
            } else {
                let width = targetSize.height * sourceAspect
                fit = CGRect(x: (targetSize.width - width) / 2, y: 0,
                             width: width, height: targetSize.height)
            }
            draw(in: fit)
        }
    }

    func normalized() -> UIImage? {
        if imageOrientation == .up { return self }
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        draw(in: CGRect(origin: .zero, size: size))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }
}
