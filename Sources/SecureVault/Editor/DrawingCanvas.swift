import SwiftUI
import CoreImage

enum DrawingTool { case arrow, oval, text, blur }

struct DrawnShape: Identifiable, Equatable {
    let id = UUID()
    var tool: DrawingTool
    // Coordinates and sizes belong to the photo, so zooming does not change saved marks.
    var start: CGPoint
    var end: CGPoint
    var color: Color
    var text: String = ""
    var points: [CGPoint] = []
    var width: CGFloat = 0.012
    var textSize: CGFloat = 0.045
}

enum AnnotationRenderer {
    private static let context = CIContext()

    static func blurred(_ image: UIImage) -> UIImage? {
        guard let input = CIImage(image: image) else { return nil }
        let output = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: image.size.width * 0.025])
            .cropped(to: input.extent)
        guard let cg = context.createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: cg, scale: image.scale, orientation: .up)
    }

    static func render(image: UIImage, shapes: [DrawnShape]) -> UIImage {
        let blur = shapes.contains { $0.tool == .blur } ? blurred(image) : nil
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { renderer in
            let bounds = CGRect(origin: .zero, size: image.size)
            image.draw(in: bounds)
            if let blur = blur {
                renderer.cgContext.saveGState()
                renderer.cgContext.addPath(blurPath(for: shapes, size: image.size))
                renderer.cgContext.clip()
                // All brush strokes share one image draw, even after a long editing session.
                blur.draw(in: bounds)
                renderer.cgContext.restoreGState()
            }
            drawVectors(shapes: shapes, in: renderer.cgContext, size: image.size)
        }
    }

    static func blurPath(for shapes: [DrawnShape], size: CGSize) -> CGPath {
        let combined = CGMutablePath()
        for shape in shapes where shape.tool == .blur {
            let points = shape.points.isEmpty ? [shape.start, shape.end] : shape.points
            guard let first = points.first else { continue }
            let path = CGMutablePath()
            let start = CGPoint(x: first.x * size.width, y: first.y * size.height)
            path.move(to: start)
            if points.count == 1 {
                path.addLine(to: CGPoint(x: start.x + 0.01, y: start.y))
            } else {
                for p in points.dropFirst() {
                    path.addLine(to: CGPoint(x: p.x * size.width, y: p.y * size.height))
                }
            }
            combined.addPath(path.copy(strokingWithWidth: max(1, size.width * shape.width),
                                       lineCap: .round, lineJoin: .round, miterLimit: 10))
        }
        return combined
    }

    static func textBounds(_ shape: DrawnShape, size: CGSize) -> CGRect {
        let origin = CGPoint(x: shape.start.x * size.width, y: shape.start.y * size.height)
        let font = UIFont.systemFont(ofSize: size.width * shape.textSize, weight: .bold)
        let available = CGSize(width: max(1, size.width - origin.x), height: max(1, size.height - origin.y))
        let measured = (shape.text as NSString).boundingRect(
            with: available, options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil)
        return CGRect(origin: origin, size: CGSize(width: min(available.width, max(1, measured.width)),
                                            height: min(available.height, max(1, measured.height))))
            .insetBy(dx: -12, dy: -12)
    }

    static func drawVectors(shapes: [DrawnShape], in ctx: CGContext, size: CGSize) {
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * size.width, y: p.y * size.height)
        }
        for shape in shapes where shape.tool != .blur {
            ctx.saveGState()
            let start = point(shape.start), end = point(shape.end)
            ctx.setStrokeColor(UIColor(shape.color).cgColor)
            ctx.setLineWidth(max(1, size.width * shape.width))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            switch shape.tool {
            case .arrow:
                let angle = atan2(end.y - start.y, end.x - start.x)
                let length = size.width * shape.width * 5
                ctx.move(to: start)
                ctx.addLine(to: end)
                ctx.move(to: end)
                ctx.addLine(to: CGPoint(x: end.x - length * cos(angle - .pi / 6),
                                        y: end.y - length * sin(angle - .pi / 6)))
                ctx.move(to: end)
                ctx.addLine(to: CGPoint(x: end.x - length * cos(angle + .pi / 6),
                                        y: end.y - length * sin(angle + .pi / 6)))
                ctx.strokePath()
            case .oval:
                ctx.strokeEllipse(in: CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                           width: abs(end.x - start.x), height: abs(end.y - start.y)))
            case .text:
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: size.width * shape.textSize, weight: .bold),
                    .foregroundColor: UIColor(shape.color),
                    .strokeColor: UIColor.black, .strokeWidth: -2
                ]
                (shape.text as NSString).draw(
                    in: CGRect(x: start.x, y: start.y,
                               width: max(1, size.width - start.x),
                               height: max(1, size.height - start.y)),
                    withAttributes: attributes)
            case .blur:
                break
            }
            ctx.restoreGState()
        }
    }
}

private final class VectorOverlayView: UIView {
    var shapes: [DrawnShape] = []
    var selectedTextID: UUID?

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        AnnotationRenderer.drawVectors(shapes: shapes, in: ctx, size: bounds.size)
        if let id = selectedTextID, let selected = shapes.first(where: { $0.id == id && $0.tool == .text }) {
            let frame = AnnotationRenderer.textBounds(selected, size: bounds.size)
            ctx.setStrokeColor(UIColor.systemOrange.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [5, 4])
            ctx.stroke(frame)
        }
    }
}

private final class AnnotationCanvasView: UIView {
    private let photoView = UIImageView()
    private let blurView = UIImageView()
    private let draftBlurView = UIImageView()
    private let vectorView = VectorOverlayView()
    private let draftVectorView = VectorOverlayView()
    private let blurMask = CAShapeLayer()
    private let draftBlurMask = CAShapeLayer()
    private(set) var preview: UIImage?
    private(set) var blurredPreview: UIImage?
    private(set) var shapes: [DrawnShape] = []
    private(set) var selectedTextID: UUID?
    private var draftShape: DrawnShape?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        for imageView in [photoView, blurView, draftBlurView] {
            imageView.contentMode = .scaleToFill
            imageView.clipsToBounds = true
            addSubview(imageView)
        }
        blurView.layer.mask = blurMask
        blurView.isHidden = true
        draftBlurView.layer.mask = draftBlurMask
        draftBlurView.isHidden = true
        // The in-progress brush uses a stroked centerline. Expanding the entire
        // path to a filled outline for every touch sample made long strokes lag.
        draftBlurMask.fillColor = nil
        draftBlurMask.strokeColor = UIColor.white.cgColor
        draftBlurMask.lineCap = .round
        draftBlurMask.lineJoin = .round
        for overlay in [vectorView, draftVectorView] {
            overlay.backgroundColor = .clear
            overlay.isOpaque = false
            overlay.contentScaleFactor = 1
            overlay.isUserInteractionEnabled = false
            addSubview(overlay)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        photoView.frame = bounds
        blurView.frame = bounds
        draftBlurView.frame = bounds
        vectorView.frame = bounds
        draftVectorView.frame = bounds
        blurMask.frame = bounds
        draftBlurMask.frame = bounds
        updateBlurMask()
        updateDraftBlurMask()
    }

    func setPreview(_ image: UIImage) {
        preview = image
        photoView.image = image
    }

    func setBlurredPreview(_ image: UIImage?) {
        blurredPreview = image
        blurView.image = image
        draftBlurView.image = image
        updateBlurMask()
        updateDraftBlurMask()
    }

    func display(_ newShapes: [DrawnShape], selectedTextID newSelection: UUID?) {
        guard shapes != newShapes || selectedTextID != newSelection else { return }
        let blurChanged = shapes.filter { $0.tool == .blur } != newShapes.filter { $0.tool == .blur }
        shapes = newShapes
        selectedTextID = newSelection
        vectorView.shapes = newShapes
        vectorView.selectedTextID = newSelection
        vectorView.setNeedsDisplay()
        if blurChanged { updateBlurMask() }
    }

    func displayDraft(_ shape: DrawnShape?, selectedTextID: UUID? = nil) {
        let unchanged: Bool
        if draftShape?.tool == .blur, shape?.tool == .blur {
            unchanged = draftShape?.id == shape?.id
                && draftShape?.points.count == shape?.points.count
                && draftShape?.width == shape?.width
                && draftVectorView.selectedTextID == selectedTextID
        } else {
            unchanged = draftShape == shape && draftVectorView.selectedTextID == selectedTextID
        }
        guard !unchanged else { return }
        let blurChanged = draftShape?.tool == .blur || shape?.tool == .blur
        let vectorChanged = (draftShape != nil && draftShape?.tool != .blur)
            || (shape != nil && shape?.tool != .blur)
            || draftVectorView.selectedTextID != selectedTextID
        draftShape = shape
        draftVectorView.shapes = shape.map { [$0] } ?? []
        draftVectorView.selectedTextID = selectedTextID
        if vectorChanged { draftVectorView.setNeedsDisplay() }
        if blurChanged { updateDraftBlurMask() }
    }

    private func updateBlurMask() {
        let hasBlur = blurredPreview != nil && shapes.contains { $0.tool == .blur }
        blurView.isHidden = !hasBlur
        guard hasBlur else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blurMask.path = AnnotationRenderer.blurPath(for: shapes, size: bounds.size)
        CATransaction.commit()
    }

    private func updateDraftBlurMask() {
        let hasBlur = blurredPreview != nil && draftShape?.tool == .blur
        draftBlurView.isHidden = !hasBlur
        guard let draftShape = draftShape, hasBlur else { return }
        let points = draftShape.points.isEmpty ? [draftShape.start, draftShape.end] : draftShape.points
        guard let first = points.first else { return }
        let path = CGMutablePath()
        let start = CGPoint(x: first.x * bounds.width, y: first.y * bounds.height)
        path.move(to: start)
        if points.count == 1 {
            path.addLine(to: CGPoint(x: start.x + 0.01, y: start.y))
        } else {
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x * bounds.width, y: point.y * bounds.height))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        draftBlurMask.lineWidth = max(1, bounds.width * draftShape.width)
        draftBlurMask.path = path
        CATransaction.commit()
    }
}

final class ZoomScrollView: UIScrollView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

struct ZoomAnnotationCanvas: UIViewRepresentable {
    let image: UIImage
    @Binding var shapes: [DrawnShape]
    var tool: DrawingTool
    var color: Color
    var text: String
    var brushWidth: CGFloat
    var textSize: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ZoomScrollView {
        let scroll = ZoomScrollView()
        let coordinator = context.coordinator
        scroll.backgroundColor = .black
        scroll.delegate = coordinator
        scroll.onLayout = { [weak coordinator] in coordinator?.fitIfNeeded() }
        scroll.panGestureRecognizer.minimumNumberOfTouches = 2
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.bouncesZoom = false
        scroll.delaysContentTouches = false

        let original = image
        let ratio = min(1, 1600 / max(original.size.width, original.size.height))
        let size = CGSize(width: original.size.width * ratio, height: original.size.height * ratio)
        let canvas = coordinator.canvas
        canvas.frame = CGRect(origin: .zero, size: size)
        canvas.isMultipleTouchEnabled = true
        scroll.addSubview(canvas)
        scroll.contentSize = size

        let draw = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.drawGesture(_:)))
        draw.maximumNumberOfTouches = 1
        draw.delegate = coordinator
        canvas.addGestureRecognizer(draw)
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.textGesture(_:)))
        tap.delegate = coordinator
        canvas.addGestureRecognizer(tap)
        let resizeText = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.resizeTextGesture(_:)))
        resizeText.delegate = coordinator
        canvas.addGestureRecognizer(resizeText)
        scroll.pinchGestureRecognizer?.require(toFail: resizeText)

        coordinator.scroll = scroll
        DispatchQueue.global(qos: .userInitiated).async { [weak coordinator] in
            let preview = original.preparingThumbnail(of: size) ?? {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    original.draw(in: CGRect(origin: .zero, size: size))
                }
            }()
            DispatchQueue.main.async { [weak coordinator] in
                guard let coordinator = coordinator, coordinator.scroll != nil else { return }
                coordinator.canvas.setPreview(preview)
                coordinator.prepareBlurIfNeeded()
            }
        }
        return scroll
    }

    func updateUIView(_ scroll: ZoomScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if tool != .text {
            coordinator.selectedTextID = nil
        } else if let selectedID = coordinator.selectedTextID,
                  !shapes.contains(where: { $0.id == selectedID }) {
            coordinator.selectedTextID = nil
        }
        coordinator.canvas.display(shapes, selectedTextID: coordinator.selectedTextID)
        coordinator.prepareBlurIfNeeded()
        coordinator.fitIfNeeded()
    }

    static func dismantleUIView(_ uiView: ZoomScrollView, coordinator: Coordinator) {
        uiView.onLayout = nil
        coordinator.scroll = nil
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: ZoomAnnotationCanvas
        fileprivate let canvas = AnnotationCanvasView()
        weak var scroll: UIScrollView?
        fileprivate var selectedTextID: UUID?
        private var viewport = CGSize.zero
        private var draft: DrawnShape?
        private var movingTextID: UUID?
        private var moveOrigin = CGPoint.zero
        private var editingText: DrawnShape?
        private var pinchTextID: UUID?
        private var initialTextSize: CGFloat = 0.045
        private var blurInProgress = false
        private var blurFailed = false

        init(_ parent: ZoomAnnotationCanvas) { self.parent = parent }

        func prepareBlurIfNeeded() {
            guard parent.tool == .blur || canvas.shapes.contains(where: { $0.tool == .blur }),
                  let preview = canvas.preview, canvas.blurredPreview == nil,
                  !blurInProgress, !blurFailed else { return }
            blurInProgress = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let blurred = AnnotationRenderer.blurred(preview)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.scroll != nil else { return }
                    self.blurInProgress = false
                    self.blurFailed = blurred == nil
                    self.canvas.setBlurredPreview(blurred)
                }
            }
        }

        func fitIfNeeded() {
            guard let scroll = scroll, scroll.bounds.width > 0, scroll.bounds.height > 0,
                  canvas.bounds.width > 0, canvas.bounds.height > 0,
                  viewport != scroll.bounds.size else { return }
            let previousRatio = scroll.minimumZoomScale > 0 ? scroll.zoomScale / scroll.minimumZoomScale : 1
            let fit = min(scroll.bounds.width / canvas.bounds.width, scroll.bounds.height / canvas.bounds.height)
            viewport = scroll.bounds.size
            scroll.minimumZoomScale = fit
            scroll.maximumZoomScale = fit * 8
            scroll.setZoomScale(min(fit * 8, max(fit, fit * previousRatio)), animated: false)
            center()
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

        private func center() {
            guard let scroll = scroll else { return }
            scroll.contentInset = UIEdgeInsets(
                top: max(0, (scroll.bounds.height - canvas.frame.height) / 2),
                left: max(0, (scroll.bounds.width - canvas.frame.width) / 2),
                bottom: max(0, (scroll.bounds.height - canvas.frame.height) / 2),
                right: max(0, (scroll.bounds.width - canvas.frame.width) / 2))
        }

        private func point(_ recognizer: UIGestureRecognizer) -> CGPoint {
            let p = recognizer.location(in: canvas)
            return CGPoint(x: min(1, max(0, p.x / max(1, canvas.bounds.width))),
                           y: min(1, max(0, p.y / max(1, canvas.bounds.height))))
        }

        private func hitText(at location: CGPoint) -> DrawnShape? {
            canvas.shapes.reversed().first {
                $0.tool == .text && AnnotationRenderer.textBounds($0, size: canvas.bounds.size).contains(location)
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer is UITapGestureRecognizer {
                return parent.tool == .text
            }
            if gestureRecognizer is UIPinchGestureRecognizer {
                guard parent.tool == .text, selectedTextID != nil else { return false }
                return hitText(at: gestureRecognizer.location(in: canvas))?.id == selectedTextID
            }
            if parent.tool == .text {
                return hitText(at: gestureRecognizer.location(in: canvas)) != nil
            }
            return true
        }

        @objc func textGesture(_ recognizer: UITapGestureRecognizer) {
            guard parent.tool == .text, recognizer.state == .ended else { return }
            if let existing = hitText(at: recognizer.location(in: canvas)) {
                selectedTextID = existing.id
                canvas.display(canvas.shapes, selectedTextID: selectedTextID)
                return
            }
            let value = parent.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            let p = point(recognizer)
            let added = DrawnShape(tool: .text, start: p, end: p, color: parent.color,
                                   text: value, textSize: parent.textSize)
            selectedTextID = added.id
            parent.shapes.append(added)
            canvas.display(parent.shapes, selectedTextID: selectedTextID)
        }

        @objc func drawGesture(_ recognizer: UIPanGestureRecognizer) {
            if parent.tool == .text {
                moveText(recognizer)
                return
            }
            let p = point(recognizer)
            var refreshDraft = false
            switch recognizer.state {
            case .began:
                draft = DrawnShape(tool: parent.tool, start: p, end: p, color: parent.color,
                                   points: [p], width: parent.tool == .blur ? parent.brushWidth : 0.006)
                refreshDraft = true
            case .changed, .ended:
                if draft?.tool == .blur {
                    if let last = draft?.points.last,
                       hypot((p.x - last.x) * canvas.bounds.width,
                             (p.y - last.y) * canvas.bounds.height) >= (recognizer.state == .ended ? 0.01 : 3) {
                        draft?.points.append(p)
                        draft?.end = p
                        refreshDraft = true
                    }
                } else {
                    draft?.end = p
                    draft?.points = [draft?.start ?? p, p]
                    refreshDraft = true
                }
                if recognizer.state == .ended, let shape = draft {
                    parent.shapes.append(shape)
                    draft = nil
                    canvas.display(parent.shapes, selectedTextID: selectedTextID)
                    refreshDraft = true
                }
            default:
                draft = nil
                refreshDraft = true
            }
            if refreshDraft { canvas.displayDraft(draft) }
        }

        private func moveText(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                guard let selected = hitText(at: recognizer.location(in: canvas)) else { return }
                movingTextID = selected.id
                selectedTextID = selected.id
                moveOrigin = selected.start
                editingText = selected
                canvas.display(parent.shapes.filter { $0.id != selected.id }, selectedTextID: nil)
                canvas.displayDraft(selected, selectedTextID: selected.id)
            case .changed, .ended:
                guard let id = movingTextID, var changed = editingText else { return }
                let translation = recognizer.translation(in: canvas)
                changed.start = CGPoint(
                    x: min(1, max(0, moveOrigin.x + translation.x / max(1, canvas.bounds.width))),
                    y: min(1, max(0, moveOrigin.y + translation.y / max(1, canvas.bounds.height))))
                changed.end = changed.start
                canvas.displayDraft(changed, selectedTextID: id)
                if recognizer.state == .ended {
                    movingTextID = nil
                    editingText = nil
                    if let index = parent.shapes.firstIndex(where: { $0.id == id }) {
                        parent.shapes[index] = changed
                    }
                    canvas.display(parent.shapes, selectedTextID: id)
                    canvas.displayDraft(nil)
                }
            default:
                movingTextID = nil
                editingText = nil
                canvas.display(parent.shapes, selectedTextID: selectedTextID)
                canvas.displayDraft(nil)
            }
        }

        @objc func resizeTextGesture(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                guard let id = selectedTextID,
                      let shape = canvas.shapes.first(where: { $0.id == id }) else { return }
                pinchTextID = id
                initialTextSize = shape.textSize
                editingText = shape
                canvas.display(parent.shapes.filter { $0.id != id }, selectedTextID: nil)
                canvas.displayDraft(shape, selectedTextID: id)
                scroll?.pinchGestureRecognizer?.isEnabled = false
            case .changed, .ended:
                guard let id = pinchTextID, var changed = editingText else { return }
                changed.textSize = min(0.18, max(0.015, initialTextSize * recognizer.scale))
                canvas.displayDraft(changed, selectedTextID: id)
                if recognizer.state == .ended {
                    if let index = parent.shapes.firstIndex(where: { $0.id == id }) {
                        parent.shapes[index] = changed
                    }
                    pinchTextID = nil
                    editingText = nil
                    canvas.display(parent.shapes, selectedTextID: id)
                    canvas.displayDraft(nil)
                    scroll?.pinchGestureRecognizer?.isEnabled = true
                }
            default:
                pinchTextID = nil
                editingText = nil
                scroll?.pinchGestureRecognizer?.isEnabled = true
                canvas.display(parent.shapes, selectedTextID: selectedTextID)
                canvas.displayDraft(nil)
            }
        }
    }
}
