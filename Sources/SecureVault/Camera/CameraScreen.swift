import SwiftUI
import CoreLocation

struct CameraScreen: View {
    @ObservedObject var cameraVM: CameraViewModel
    let onCapture: (UIImage, CLLocation?, CLHeading?) -> Void
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var locationManager = LocationManager.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var blackScreen = false
    @State private var savedBrightness: CGFloat?
    @State private var savedIdleTimer: Bool?
    @State private var pinchStart: Double?
    @Environment(\.scenePhase) private var scenePhase

    private var currentAccuracy: Double? {
        let acc = locationManager.location?.horizontalAccuracy ?? -1
        return acc >= 0 ? acc : nil
    }

    private var captureButtonColor: Color {
        guard let accuracy = currentAccuracy else { return .white }
        if accuracy <= 10 {
            return .green
        } else if accuracy <= 20 {
            return .orange
        } else {
            return .red
        }
    }

    private var isCaptureBlocked: Bool {
        guard settings.accuracyProtectionEnabled else { return false }
        guard let location = locationManager.location,
              abs(location.timestamp.timeIntervalSinceNow) < 15,
              let accuracy = currentAccuracy else { return true }
        return accuracy > Double(settings.accuracyThreshold)
    }

    private var distanceFromLastPhoto: Double? {
        guard settings.distanceTrackingEnabled else { return nil }
        guard let current = locationManager.location else { return nil }
        guard let last = FileStorageManager.shared.lastPhotoLocation() else { return nil }
        return current.distance(from: last)
    }

    private var isDistanceViolation: Bool {
        guard let d = distanceFromLastPhoto else { return false }
        return d < Double(settings.minDistanceThreshold)
    }

    var body: some View {
        ZStack {
            CameraView(session: cameraVM.session) { scale, state in
                guard !blackScreen else { return }
                switch state {
                case .began:
                    pinchStart = cameraVM.zoom
                case .changed:
                    if pinchStart == nil { pinchStart = cameraVM.zoom }
                    cameraVM.setZoom((pinchStart ?? cameraVM.zoom) * Double(scale))
                default:
                    pinchStart = nil
                }
            }
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Верхняя панель — координаты
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        if let loc = locationManager.location {
                            Text(String(format: "%.6f, %.6f",
                                        loc.coordinate.latitude,
                                        loc.coordinate.longitude))
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                        } else {
                            Text("Определение координат...")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.6))
                        }
                        if let hdg = locationManager.heading {
                            let dir = locationManager.compassDirection(from: hdg.magneticHeading)
                            Text(String(format: "AZM: %d° %@", Int(hdg.magneticHeading), dir))
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundColor(.white.opacity(0.85))
                        }
                        if let distance = distanceFromLastPhoto {
                            Text(String(format: "До посл. фото: %.0f м", distance))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(isDistanceViolation ? .red : .green)
                        }
                    }
                    Spacer()
                    if let loc = locationManager.location {
                        HStack(spacing: 4) {
                            Text("±\(Int(loc.horizontalAccuracy))м")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.white)
                            Circle()
                                .fill(captureButtonColor)
                                .frame(width: 10, height: 10)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.5))

                if isCaptureBlocked {
                    Text("Нет свежих точных координат (порог \(settings.accuracyThreshold) м) — съёмка заблокирована")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.85))
                }

                if isDistanceViolation {
                    Text("Слишком близко к последнему фото — минимум \(settings.minDistanceThreshold) м")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.85))
                }

                Spacer()

                // Перекрестие — центрируется именно в свободной зоне между панелями
                if settings.showCrosshair {
                    CrosshairView(color: settings.crosshairColor)
                }

                Spacer()

                VStack(spacing: 16) {
                    if settings.foldersEnabled && cameraVM.event == nil {
                        Picker("Режим", selection: $settings.activeWorkMode) {
                            ForEach(settings.workModes, id: \.self) { Text($0).tag($0) }
                        }.pickerStyle(.menu).padding(.horizontal)
                    }
                    if let event = cameraVM.event {
                        HStack {
                            Text("Событие \(event.eventNumber) · кадр \(event.index)/\(event.expectedCount) · \(event.folder)")
                            Spacer()
                            Button("Завершить") { cameraVM.finishEvent() }
                                .disabled(cameraVM.isCapturing)
                        }.font(.caption).foregroundColor(.orange).padding(.horizontal)
                    } else {
                        Text("Новое событие · \(settings.photosPerEvent) фото").font(.caption).foregroundColor(.white)
                    }
                    HStack(spacing: 40) {
                        Button {
                            cameraVM.toggleTorch()
                        } label: {
                            Image(systemName: cameraVM.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                                .font(.system(size: 24))
                                .foregroundColor(cameraVM.isTorchOn ? .yellow : .white)
                                .frame(width: 50, height: 50)
                                .background(Color.black.opacity(0.4))
                                .clipShape(Circle())
                        }

                        Button {
                            guard !isCaptureBlocked, !blackScreen else { return }
                            cameraVM.capturePhoto { img, loc, hdg in
                                onCapture(img, loc, hdg)
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .stroke(isCaptureBlocked ? Color.gray : captureButtonColor, lineWidth: 3)
                                    .frame(width: 72, height: 72)
                                Circle()
                                    .fill(isCaptureBlocked ? Color.gray.opacity(0.5) : captureButtonColor)
                                    .frame(width: 60, height: 60)
                            }
                        }
                        .disabled(isCaptureBlocked || cameraVM.isCapturing)

                        Button {
                            cameraVM.quickMode.toggle()
                        } label: {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 24))
                                .foregroundColor(cameraVM.quickMode ? .orange : .white)
                                .frame(width: 50, height: 50)
                                .background(Color.black.opacity(0.4))
                                .clipShape(Circle())
                        }
                        .disabled(cameraVM.isCapturing)
                    }

                    HStack {
                        Button("Отмена") { dismiss() }
                            .foregroundColor(.white.opacity(0.8))
                            .disabled(cameraVM.isCapturing)
                        Spacer()
                        if cameraVM.quickMode {
                            Text("Быстрый режим")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 40)
                .background(Color.black.opacity(0.5))
            }
            .allowsHitTesting(!blackScreen)
            if blackScreen {
                Color.black.ignoresSafeArea().contentShape(Rectangle())
            }
        }
        .background(ThreeFingerDoubleTap(enabled: settings.blackScreenEnabled) { setBlackScreen(!blackScreen) })
        .statusBarHidden(blackScreen)
        .persistentSystemOverlays(blackScreen ? .hidden : .automatic)
        .onAppear {
            cameraVM.startSession()
            locationManager.requestAndStart()
            if settings.volumeButtonCaptureEnabled {
                VolumeButtonHandler.shared.onTrigger = {
                    guard !isCaptureBlocked, !blackScreen else { return }
                    cameraVM.capturePhoto { img, loc, hdg in
                        onCapture(img, loc, hdg)
                    }
                }
                VolumeButtonHandler.shared.start()
            }
        }
        .onDisappear {
            VolumeButtonHandler.shared.stop()
            setBlackScreen(false)
            cameraVM.stopSession()
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { setBlackScreen(false); cameraVM.stopSession() }
            else { cameraVM.startSession(); locationManager.requestAndStart() }
        }
        .onChange(of: settings.blackScreenEnabled) { if !$0 { setBlackScreen(false) } }
        .alert("Камера", isPresented: Binding(get: { cameraVM.error != nil }, set: { if !$0 { cameraVM.error = nil } })) {
            Button("Закрыть") { cameraVM.error = nil }
        } message: { Text(cameraVM.error ?? "") }
    }

    private func setBlackScreen(_ enabled: Bool) {
        guard blackScreen != enabled else { return }
        guard !enabled || !cameraVM.isCapturing else { return }
        pinchStart = nil
        blackScreen = enabled
        if enabled {
            savedBrightness = UIScreen.main.brightness
            savedIdleTimer = UIApplication.shared.isIdleTimerDisabled
            UIScreen.main.brightness = 0
            UIApplication.shared.isIdleTimerDisabled = true
            cameraVM.stopSession()
        } else {
            if let brightness = savedBrightness { UIScreen.main.brightness = brightness }
            if let idleTimer = savedIdleTimer { UIApplication.shared.isIdleTimerDisabled = idleTimer }
            savedBrightness = nil; savedIdleTimer = nil
            if scenePhase == .active { cameraVM.startSession() }
        }
        NotificationCenter.default.post(name: .blackScreenChanged, object: enabled)
    }
}
