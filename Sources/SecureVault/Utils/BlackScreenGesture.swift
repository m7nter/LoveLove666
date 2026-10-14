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
        DispatchQueue.main.async { coordinator.attach(to: view.window) }
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
