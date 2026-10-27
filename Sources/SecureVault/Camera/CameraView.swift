// CameraView.swift
import SwiftUI
import AVFoundation
import UIKit

struct CameraView: UIViewRepresentable {
    let session: AVCaptureSession
    var showsCrosshair: Bool = false
    var crosshairColor: String = "white"
    let onPinch: (CGFloat, UIGestureRecognizer.State) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPinch: onPinch) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.session = session
        view.setCrosshair(visible: showsCrosshair, color: crosshairColor)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.onPinch = onPinch
        uiView.setCrosshair(visible: showsCrosshair, color: crosshairColor)
    }

    final class Coordinator: NSObject {
        var onPinch: (CGFloat, UIGestureRecognizer.State) -> Void

        init(onPinch: @escaping (CGFloat, UIGestureRecognizer.State) -> Void) {
            self.onPinch = onPinch
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            onPinch(gesture.scale, gesture.state)
        }
    }
}

class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    private let aimLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        aimLayer.name = "camera.aim"
        aimLayer.fillColor = UIColor.clear.cgColor
        aimLayer.lineWidth = 2
        aimLayer.isHidden = true
        layer.addSublayer(aimLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setCrosshair(visible: Bool, color: String) {
        aimLayer.isHidden = !visible
        let tint: UIColor
        switch color {
        case "red": tint = .red
        case "green": tint = .green
        case "yellow": tint = .yellow
        default: tint = .white
        }
        aimLayer.strokeColor = tint.cgColor
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The aim belongs to the actual preview, not the remaining space
        // between UI panels. Aspect-fill crops symmetrically around this point.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        aimLayer.frame = bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: center.x - 20, y: center.y))
        path.addLine(to: CGPoint(x: center.x + 20, y: center.y))
        path.move(to: CGPoint(x: center.x, y: center.y - 20))
        path.addLine(to: CGPoint(x: center.x, y: center.y + 20))
        aimLayer.path = path.cgPath
        CATransaction.commit()
        if let connection = previewLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }

    var session: AVCaptureSession? {
        didSet { previewLayer.session = session; previewLayer.videoGravity = .resizeAspectFill; setNeedsLayout() }
    }
}
