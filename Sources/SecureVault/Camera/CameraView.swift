// CameraView.swift
import SwiftUI
import AVFoundation
import UIKit

struct CameraView: UIViewRepresentable {
    let session: AVCaptureSession
    let onPinch: (CGFloat, UIGestureRecognizer.State) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPinch: onPinch) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.session = session
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.onPinch = onPinch
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

    var session: AVCaptureSession? {
        didSet { previewLayer.session = session; previewLayer.videoGravity = .resizeAspectFill }
    }
}
