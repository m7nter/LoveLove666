import UIKit
import CoreLocation

struct WatermarkRenderer {
    static func apply(to image: UIImage,
                      location: CLLocation?,
                      heading: CLHeading?,
                      labelText: String? = nil) -> UIImage {

        // Keep the same orientation path as the working LoveShop renderer.
        // The pixel-aspect wrapper introduced an extra fit pass and could
        // subtly stretch camera JPEGs with EXIF orientation metadata.
        guard let normalized = image.normalized() else { return image }
        let size = normalized.size
        let padding = size.width * 0.03
        let avatarImage = SettingsStore.shared.avatarImage
        let hasLabel = !(labelText ?? "").isEmpty
        let avatarSize: CGFloat = size.width * 0.22
        let labelFont = UIFont.systemFont(ofSize: max(size.width * 0.03, 18), weight: .medium)
        let labelWidth = max(1, size.width - avatarSize - padding * 3)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: UIColor.white
        ]
        let labelHeight: CGFloat
        if hasLabel, let labelText {
            let measured = labelText.boundingRect(
                with: CGSize(width: labelWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: labelAttrs,
                context: nil)
            labelHeight = ceil(max(labelFont.lineHeight, measured.height))
        } else {
            labelHeight = 0
        }
        let footerContentHeight = max(avatarImage == nil ? 0 : avatarSize, labelHeight)
        let footerHeight = footerContentHeight > 0 ? footerContentHeight + padding * 2 : 0
        let outputSize = CGSize(width: size.width, height: size.height + footerHeight)
        // Preserve the source bitmap scale. UIGraphicsImageRenderer's default
        // uses the current screen scale, which changed an 800×600 photo into
        // 1200×900 on the simulator and made exported photos look stretched.
        let format = UIGraphicsImageRendererFormat()
        format.scale = normalized.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
        let result = renderer.image { _ in
            normalized.draw(at: .zero)

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
                let accuracyLimit = SettingsStore.shared.accuracyProtectionEnabled
                    ? Double(SettingsStore.shared.accuracyThreshold) : 15
                let isAccurate = (location?.horizontalAccuracy ?? 999) <= accuracyLimit
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
            if hasLabel || avatarImage != nil {
                // The footer is outside the photo. The photo keeps its full
                // original rectangle and is never fitted around the label.
                let bottomY = size.height

                UIColor.black.setFill()
                UIRectFill(CGRect(x: 0, y: bottomY, width: size.width, height: footerHeight))

                if let label = labelText, !label.isEmpty {
                    let labelRect = CGRect(
                        x: padding, y: bottomY + padding,
                        width: labelWidth,
                        height: footerHeight - padding * 2)
                    (label as NSString).draw(with: labelRect,
                                             options: [.usesLineFragmentOrigin, .usesFontLeading],
                                             attributes: labelAttrs,
                                             context: nil)
                }

                if let avatar = avatarImage {
                    let avatarX = size.width - avatarSize - padding
                    let avatarY = bottomY + padding
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
                let cy = topBarH + (size.height - topBarH) / 2
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
    func normalized() -> UIImage? {
        if imageOrientation == .up { return self }
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        draw(in: CGRect(origin: .zero, size: size))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }
}

