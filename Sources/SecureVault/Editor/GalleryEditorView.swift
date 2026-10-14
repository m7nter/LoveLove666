import SwiftUI

struct GalleryEditorView: View {
    let image: UIImage
    let url: URL
    let onSaved: (UIImage) -> Void
    @Environment(\.dismiss) var dismiss
    private let accessGeneration = VaultGate.shared.generation
    var body: some View {
        PhotoEditingView(image: image, addWatermark: false, location: nil, heading: nil, onSave: { result, complete in
            let epoch = accessGeneration
            DispatchQueue.global(qos: .userInitiated).async {
                let saved = FileStorageManager.shared.overwrite(image: result, at: url, generation: epoch)
                DispatchQueue.main.async {
                    complete(saved)
                    if saved { onSaved(result); dismiss() }
                }
            }
        }, onCancel: { dismiss() })
    }
}
