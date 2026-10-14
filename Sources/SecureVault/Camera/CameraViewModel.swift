import AVFoundation
import UIKit
import Combine
import CoreLocation

final class CameraViewModel: NSObject, ObservableObject {
    @Published var capturedImage: UIImage?
    @Published var error: String?
    @Published var isTorchOn = false
    @Published var quickMode = false
    @Published var isCapturing = false
    // The zoom gesture updates these values continuously. Publishing every change
    // forces the whole camera screen to redraw while the user is pinching.
    private(set) var zoom: Double = 1
    private(set) var minimumZoom: Double = 1
    private(set) var maximumZoom: Double = 2
    @Published var event: CaptureContext?
    private(set) var pendingContext: CaptureContext?
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "SecureVault.camera")
    private let photoOutput = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var photoDimensions: CMVideoDimensions?
    private var zoomMultiplier: Double = 1
    private let zoomStateLock = NSLock()
    private var pendingZoom: Double?
    private var zoomApplyScheduled = false
    private var configured = false
    private var wantsSession = false
    private var completion: ((UIImage, CLLocation?, CLHeading?) -> Void)?
    private var shotLocation: CLLocation?
    private var shotHeading: CLHeading?
    private let ownerGeneration = VaultGate.shared.generation

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "pendingCaptureEvent") {
            event = try? JSONDecoder().decode(CaptureContext.self, from: data)
            reconcileEvent()
        }
    }

    func startSession() {
        guard (try? VaultGate.shared.withAccess(generation: ownerGeneration) { true }) == true else { return }
        queue.async { self.wantsSession = true }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { allowed in
                if allowed { self.configureAndStart() }
                else { self.reportError("Разрешите доступ к камере в настройках iPhone") }
            }
        default: reportError("Разрешите доступ к камере в настройках iPhone")
        }
    }

    private func configureAndStart() {
        queue.async {
            guard self.wantsSession else { return }
            guard (try? VaultGate.shared.withAccess(generation: self.ownerGeneration) { true }) == true else { return }
            if !self.configured {
                let discovery = AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera],
                    mediaType: .video,
                    position: .back
                )
                // Use one virtual input for a continuous ultrawide-to-wide pinch.
                let virtualDevices = discovery.devices.filter { candidate in
                    let types = candidate.constituentDevices.map(\.deviceType)
                    return types.contains(.builtInUltraWideCamera) && types.contains(.builtInWideAngleCamera)
                }
                // 0.5–2× needs only ultrawide and wide. Prefer that virtual
                // pair over the triple device when both are present.
                let device = virtualDevices.first(where: { $0.deviceType == .builtInDualWideCamera })
                    ?? virtualDevices.first(where: { $0.deviceType == .builtInTripleCamera })
                    ?? discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera })
                guard let device else {
                    self.reportError("Камера недоступна"); return
                }
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    self.session.beginConfiguration()
                    guard self.session.canAddInput(input), self.session.canAddOutput(self.photoOutput) else {
                        self.session.commitConfiguration()
                        self.reportError("Не удалось настроить камеру"); return
                    }
                    self.session.sessionPreset = .photo
                    self.session.addInput(input)
                    self.session.addOutput(self.photoOutput)
                    self.session.commitConfiguration()
                    self.device = device
                    self.photoDimensions = Self.preferredPhotoDimensions(for: device)
                    if let dimensions = self.photoDimensions {
                        self.photoOutput.maxPhotoDimensions = dimensions
                    }
                    let lenses = device.constituentDevices.map(\.deviceType)
                    if lenses.contains(.builtInUltraWideCamera), lenses.contains(.builtInWideAngleCamera) {
                        // AVFoundation's device factor can start at 1 on the
                        // ultrawide lens; use its system display multiplier.
                        let displayMultiplier: Double
                        if #available(iOS 18.0, *) {
                            displayMultiplier = Double(device.displayVideoZoomFactorMultiplier)
                        } else {
                            displayMultiplier = 0
                        }
                        let firstSwitch = device.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue ?? 0
                        let inferredMultiplier = firstSwitch > 1 ? 1 / firstSwitch : 1
                        self.zoomMultiplier = (displayMultiplier > 0 && displayMultiplier < 1)
                            ? displayMultiplier : inferredMultiplier
                    } else {
                        self.zoomMultiplier = 1
                    }
                    let lower = max(0.5, Double(device.minAvailableVideoZoomFactor) * self.zoomMultiplier)
                    let upper = min(2, Double(device.maxAvailableVideoZoomFactor) * self.zoomMultiplier)
                    try device.lockForConfiguration()
                    device.videoZoomFactor = CGFloat(min(upper, max(lower, 1)) / self.zoomMultiplier)
                    device.unlockForConfiguration()
                    self.configured = true
                    DispatchQueue.main.async {
                        self.minimumZoom = lower; self.maximumZoom = max(lower, upper)
                        self.zoom = min(upper, max(lower, 1))
                    }
                } catch { self.reportError("Ошибка камеры: \(error.localizedDescription)"); return }
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stopSession() {
        queue.async {
            self.wantsSession = false
            if let device = self.device, device.hasTorch {
                do { try device.lockForConfiguration(); device.torchMode = .off; device.unlockForConfiguration() }
                catch { self.reportError("Не удалось отключить фонарик") }
            }
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isTorchOn = false }
        }
    }

    func setZoom(_ value: Double) {
        let clamped = min(maximumZoom, max(minimumZoom, value))
        zoom = clamped
        zoomStateLock.lock()
        pendingZoom = clamped
        let needsSchedule = !zoomApplyScheduled
        if needsSchedule { zoomApplyScheduled = true }
        zoomStateLock.unlock()
        if needsSchedule { queue.async { self.applyPendingZoom() } }
    }

    private func applyPendingZoom() {
        zoomStateLock.lock()
        let requested = pendingZoom
        pendingZoom = nil
        zoomStateLock.unlock()

        if let requested = requested, let device = device {
            do {
                try device.lockForConfiguration()
                let factor = CGFloat(requested / zoomMultiplier)
                let target = min(device.maxAvailableVideoZoomFactor, max(device.minAvailableVideoZoomFactor, factor))
                if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
                device.videoZoomFactor = target
                device.unlockForConfiguration()
            } catch { reportError("Не удалось изменить увеличение") }
        }

        zoomStateLock.lock()
        let hasMore = pendingZoom != nil
        if !hasMore { zoomApplyScheduled = false }
        zoomStateLock.unlock()
        if hasMore { queue.async { self.applyPendingZoom() } }
    }

    func toggleTorch() {
        queue.async {
            guard let device = self.device, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                let enabled = device.torchMode != .on
                device.torchMode = enabled ? .on : .off
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.isTorchOn = enabled }
            } catch { self.reportError("Фонарик недоступен") }
        }
    }

    func capturePhoto(completion: @escaping (UIImage, CLLocation?, CLHeading?) -> Void) {
        guard (try? VaultGate.shared.withAccess(generation: ownerGeneration) { true }) == true else { return }
        guard !isCapturing, session.isRunning else { return }
        if event == nil { event = FileStorageManager.shared.newEvent(); persistEvent() }
        pendingContext = event
        pendingContext?.capturedAt = Date()
        isCapturing = true
        self.completion = completion
        let location = LocationManager.shared.location
        shotLocation = location.flatMap { $0.horizontalAccuracy >= 0 && abs($0.timestamp.timeIntervalSinceNow) < 15 ? $0 : nil }
        shotHeading = LocationManager.shared.heading
        queue.async {
            let settings = AVCapturePhotoSettings()
            if let dimensions = self.photoDimensions { settings.maxPhotoDimensions = dimensions }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func didSavePhoto() {
        guard var current = event else { return }
        if current.index >= current.expectedCount {
            event = nil
        }
        else { current.index += 1; event = current }
        pendingContext = nil
        persistEvent()
    }

    func finishEvent() {
        if let current = event { FileStorageManager.shared.completeEvent(current.eventID) }
        event = nil; pendingContext = nil; persistEvent()
    }
    private func reconcileEvent() {
        guard var current = event else { return }
        guard current.generation == nil || current.generation == ownerGeneration else { event = nil; persistEvent(); return }
        current.generation = ownerGeneration
        let storage = FileStorageManager.shared
        let members = storage.loadAll().filter { storage.loadMeta(for: $0)?.eventID == current.eventID }
        if let first = members.first {
            current.folder = storage.folder(for: first)
            let lastIndex = members.compactMap { storage.loadMeta(for: $0)?.eventIndex }.max() ?? 0
            current.index = max(current.index, lastIndex + 1)
            if current.index > current.expectedCount { event = nil }
            else { event = current }
        } else if current.index > 1 { event = nil }
        else { event = current }
        persistEvent()
    }
    private func persistEvent() {
        if let event = event, let data = try? JSONEncoder().encode(event) {
            UserDefaults.standard.set(data, forKey: "pendingCaptureEvent")
        } else { UserDefaults.standard.removeObject(forKey: "pendingCaptureEvent") }
    }
    private func reportError(_ message: String) { DispatchQueue.main.async { self.error = message } }

    private static func preferredPhotoDimensions(for device: AVCaptureDevice) -> CMVideoDimensions? {
        let fourByThree = device.activeFormat.supportedMaxPhotoDimensions.filter { dimensions in
            let longSide = Double(max(dimensions.width, dimensions.height))
            let shortSide = Double(min(dimensions.width, dimensions.height))
            return shortSide > 0 && abs(longSide / shortSide - 4.0 / 3.0) < 0.02
        }
        // Around 12 MP gives the original camera's useful detail without the
        // latency and memory pressure of an optional 48 MP capture format.
        let standard = fourByThree.filter { Int64($0.width) * Int64($0.height) <= 16_000_000 }
        return (standard.isEmpty ? fourByThree : standard).max {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }
    }
}

extension CameraViewModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap { UIImage(data: $0) }
        DispatchQueue.main.async {
            self.isCapturing = false
            guard (try? VaultGate.shared.withAccess(generation: self.ownerGeneration) { true }) == true else {
                self.completion = nil; self.shotLocation = nil; self.shotHeading = nil; self.pendingContext = nil; self.event = nil
                return
            }
            guard error == nil, let image = image else {
                self.error = "Не удалось снять фото. Повторите кадр."; return
            }
            self.completion?(image, self.shotLocation, self.shotHeading)
            self.completion = nil
        }
    }
}
