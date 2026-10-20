import SwiftUI

extension Notification.Name {
    static let blackScreenChanged = Notification.Name("blackScreenChanged")
}

// The recognizer attaches to the camera's containing window without covering its controls.
struct ThreeFingerDoubleTap: UIViewRepresentable {
    var enabled: Bool
    let onTap: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView {
        let view = GestureAnchor()
        view.isUserInteractionEnabled = false
        view.moved = { [weak coordinator = context.coordinator] window in coordinator?.attach(to: window) }
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.action = onTap
        coordinator.enabled = enabled
        // SwiftUI can perform the first update before the representable has
        // entered a window. In that case the old one-shot attach left the
        // recognizer disabled until the camera view was rebuilt. Retry on the
        // next run-loop turn and once after layout so the first two-triple-tap
        // gesture is always observed when the camera appears.
        func attachWhenReady() {
            coordinator.attach(to: view.window)
            if view.window == nil {
                DispatchQueue.main.async { coordinator.attach(to: view.window) }
            }
        }
        DispatchQueue.main.async(execute: attachWhenReady)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            coordinator.attach(to: view.window)
        }
    }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.detach() }
    final class Coordinator: NSObject {
        var action: (() -> Void)?
        var enabled = false
        private weak var window: UIWindow?
        private var destroyed = false
        private lazy var recognizer: UITapGestureRecognizer = {
            let tap = UITapGestureRecognizer(target: self, action: #selector(trigger))
            tap.numberOfTouchesRequired = 3
            tap.numberOfTapsRequired = 2
            // Camera controls may consume the first touch sequence while the
            // window-level recognizer is settling in. It must observe the
            // sequence without cancelling the camera's own touches.
            tap.cancelsTouchesInView = false
            return tap
        }()
        func attach(to newWindow: UIWindow?) {
            guard !destroyed else { return }
            if window !== newWindow {
                window?.removeGestureRecognizer(recognizer)
                window = newWindow; window?.addGestureRecognizer(recognizer)
            }
            recognizer.isEnabled = enabled
        }
        func detach() { destroyed = true; window?.removeGestureRecognizer(recognizer); window = nil }
        @objc private func trigger() { if enabled { action?() } }
    }
}

private final class GestureAnchor: UIView {
    var moved: ((UIWindow?) -> Void)?
    override func didMoveToWindow() { super.didMoveToWindow(); moved?(window) }
}
