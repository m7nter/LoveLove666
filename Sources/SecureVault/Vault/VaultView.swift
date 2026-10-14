import SwiftUI
import CoreLocation

struct VaultView: View {
    @StateObject private var cameraVM = CameraViewModel()
    @State private var showCamera = false
    @State private var capturedImage: UIImage?
    @State private var capturedLocation: CLLocation?
    @State private var capturedHeading: CLHeading?
    @State private var showEditor = false
    @State private var showGallery = false
    @State private var showMap = false
    @State private var showNotes = false
    @State private var showVaultLock = false
    @State private var pendingDestination: Destination?
    @State private var saveError = false
    @State private var isSavingQuickPhoto = false
    let cameraOnly: Bool
    var onLock: () -> Void

    init(cameraOnly: Bool = false, onLock: @escaping () -> Void) {
        self.cameraOnly = cameraOnly
        self.onLock = onLock
        _showCamera = State(initialValue: cameraOnly)
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(hex: "#1C1C1E").ignoresSafeArea()
                if !cameraOnly {
                VStack(spacing: 24) {
                    Image(systemName: "lock.shield.fill").font(.system(size: 64)).foregroundColor(.orange)
                    Text("Хранилище").font(.title.bold()).foregroundColor(.white)
                    HStack(spacing: 16) {
                        VaultActionButton(icon: "camera.fill", label: "Камера") { showCamera = true }
                        VaultActionButton(icon: "folder.fill", label: "Папки") { requestAccess(to: .gallery) }
                    }
                    HStack(spacing: 16) {
                        VaultActionButton(icon: "map.fill", label: "Карта меток") { requestAccess(to: .map) }
                        VaultActionButton(icon: "note.text", label: "Дневник") { requestAccess(to: .notes) }
                    }
                    Button("Калькулятор", action: onLock).foregroundColor(.gray)
                }
                }
            }.navigationBarHidden(true)
        }
        .onAppear {
            LocationManager.shared.requestAndStart()
            if cameraOnly { showCamera = true }
        }
        .onDisappear {
            cameraVM.stopSession()
            LocationManager.shared.stop()
        }
        .fullScreenCover(isPresented: $showCamera, onDismiss: {
            showEditor = false; capturedImage = nil; cameraVM.stopSession()
            if cameraOnly { onLock() }
        }) {
            Group {
                if showEditor, let image = capturedImage {
                    PhotoEditorView(image: image, location: capturedLocation, heading: capturedHeading, onSave: { result, complete in
                        save(result) { saved in
                            complete(saved)
                            if saved {
                                showEditor = false; capturedImage = nil
                                if cameraVM.event == nil { showCamera = false }
                            }
                        }
                    }, onDiscard: {
                        showEditor = false; capturedImage = nil
                    })
                } else {
                    CameraScreen(cameraVM: cameraVM, onCapture: receivePhoto)
                        .overlay {
                            if isSavingQuickPhoto {
                                ProgressView("Сохранение фото…")
                                    .padding(20)
                                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                }
            }
            .alert("Фото не сохранено", isPresented: $saveError) {
                Button("Повторить сохранение") {
                    if let image = capturedImage {
                        save(image) { saved in
                            if saved {
                                capturedImage = nil
                                if cameraVM.event == nil { showCamera = false }
                            } else { saveError = true }
                        }
                    }
                }
                Button("Отбросить кадр", role: .destructive) { capturedImage = nil }
            } message: { Text("Проверьте свободное место. Кадр события не засчитан.") }
        }
        .fullScreenCover(isPresented: $showGallery) { GalleryView() }
        .fullScreenCover(isPresented: $showNotes) { NotesListView() }
        .fullScreenCover(isPresented: $showMap) { PhotoMapView() }
        .fullScreenCover(isPresented: $showVaultLock) {
            VaultLockView {
                showVaultLock = false
                let destination = pendingDestination
                pendingDestination = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { open(destination) }
            } onCancel: { showVaultLock = false; pendingDestination = nil }
        }
    }

    private func receivePhoto(_ image: UIImage, _ location: CLLocation?, _ heading: CLHeading?) {
        capturedLocation = location; capturedHeading = heading
        if cameraVM.quickMode {
            let label = UserDefaults.standard.string(forKey: "selectedTemplate").flatMap { $0.isEmpty ? nil : $0 }
            let context = cameraVM.pendingContext
            isSavingQuickPhoto = true
            cameraVM.isCapturing = true
            DispatchQueue.global(qos: .userInitiated).async {
                let result = WatermarkRenderer.apply(to: image, location: location, heading: heading, labelText: label)
                let saved = FileStorageManager.shared.save(image: result, location: location, context: context) != nil
                DispatchQueue.main.async {
                    isSavingQuickPhoto = false
                    cameraVM.isCapturing = false
                    if saved {
                        cameraVM.didSavePhoto()
                        if cameraVM.event == nil { showCamera = false }
                    } else { capturedImage = result; saveError = true }
                }
            }
        } else { capturedImage = image; showEditor = true }
    }
    private func save(_ image: UIImage, completion: @escaping (Bool) -> Void) {
        let location = capturedLocation
        let context = cameraVM.pendingContext
        isSavingQuickPhoto = true
        cameraVM.isCapturing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let saved = FileStorageManager.shared.save(image: image, location: location, context: context) != nil
            DispatchQueue.main.async {
                isSavingQuickPhoto = false
                cameraVM.isCapturing = false
                if saved { cameraVM.didSavePhoto() }
                completion(saved)
            }
        }
    }
    private enum Destination { case gallery, notes, map }
    private func open(_ destination: Destination?) {
        guard !cameraOnly, (try? VaultGate.shared.withAccess { true }) == true else { return }
        switch destination { case .gallery: showGallery = true; case .notes: showNotes = true; case .map: showMap = true; case .none: break }
    }
    private func requestAccess(to destination: Destination) {
        guard !cameraOnly, (try? VaultGate.shared.withAccess { true }) == true else { return }
        let store = SettingsStore.shared
        if store.vaultCodeEnabled {
            pendingDestination = destination; showVaultLock = true
        } else { open(destination) }
    }
}

struct VaultActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 32)).foregroundColor(.white)
                Text(label).font(.caption).foregroundColor(.gray)
            }
            .frame(width: 130, height: 100).background(Color(hex: "#2C2C2E")).cornerRadius(16)
        }
    }
}
