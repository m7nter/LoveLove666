import AVFoundation
import MediaPlayer
import UIKit

final class VolumeButtonHandler: NSObject {
    static let shared = VolumeButtonHandler()

    var onTrigger: (() -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var initialVolume: Float = 0.5
    private var volumeView: MPVolumeView?
    private var isAdjustingVolume = false
    private var isListening = false

    func start() {
        guard !isListening else { return }
        isListening = true

        try? session.setCategory(.ambient, options: [.mixWithOthers])
        try? session.setActive(true)

        initialVolume = session.outputVolume
        if initialVolume > 0.9 { initialVolume = 0.9 }
        if initialVolume < 0.1 { initialVolume = 0.1 }
        setSystemVolume(initialVolume)

        session.addObserver(self, forKeyPath: "outputVolume", options: [.new], context: nil)

        // Невидимый MPVolumeView нужен, чтобы получить доступ к системному слайдеру громкости
        let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        view.alpha = 0.0001
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.windows.first })
            .first {
            window.addSubview(view)
        }
        volumeView = view
    }

    func stop() {
        onTrigger = nil
        guard isListening else { return }
        isListening = false
        session.removeObserver(self, forKeyPath: "outputVolume")
        volumeView?.removeFromSuperview()
        volumeView = nil
    }

    override func observeValue(forKeyPath keyPath: String?,
                               of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        guard keyPath == "outputVolume" else { return }
        DispatchQueue.main.async {
            guard self.isListening, !self.isAdjustingVolume else { return }
            self.isAdjustingVolume = true
            self.onTrigger?()
            self.setSystemVolume(self.initialVolume)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.isAdjustingVolume = false
            }
        }
    }

    private func setSystemVolume(_ volume: Float) {
        guard let slider = volumeView?.subviews.first(where: { $0 is UISlider }) as? UISlider else { return }
        slider.value = volume
    }
}
