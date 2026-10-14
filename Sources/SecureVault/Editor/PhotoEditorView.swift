import SwiftUI
import CoreLocation

class LabelTemplatesStore: ObservableObject {
    @Published var templates: [String] {
        didSet { UserDefaults.standard.set(templates, forKey: "labelTemplates") }
    }
    @Published var selected: String {
        didSet { UserDefaults.standard.set(selected, forKey: "selectedTemplate") }
    }
    init() {
        templates = UserDefaults.standard.stringArray(forKey: "labelTemplates") ?? []
        selected = UserDefaults.standard.string(forKey: "selectedTemplate") ?? ""
    }
}

struct PhotoEditorView: View {
    let image: UIImage
    let location: CLLocation?
    let heading: CLHeading?
    let onSave: (UIImage, @escaping (Bool) -> Void) -> Void
    let onDiscard: () -> Void
    var body: some View {
        PhotoEditingView(image: image, addWatermark: true, location: location, heading: heading,
                         onSave: onSave, onCancel: onDiscard)
    }
}

struct PhotoEditingView: View {
    let image: UIImage
    let addWatermark: Bool
    let location: CLLocation?
    let heading: CLHeading?
    let onSave: (UIImage, @escaping (Bool) -> Void) -> Void
    let onCancel: () -> Void
    private let accessGeneration = VaultGate.shared.generation
    init(image: UIImage, addWatermark: Bool, location: CLLocation?, heading: CLHeading?,
         onSave: @escaping (UIImage, @escaping (Bool) -> Void) -> Void, onCancel: @escaping () -> Void) {
        self.image = image; self.addWatermark = addWatermark
        self.location = location; self.heading = heading
        self.onSave = onSave; self.onCancel = onCancel
    }
    @StateObject private var templates = LabelTemplatesStore()
    @State private var shapes: [DrawnShape] = []
    @State private var tool: DrawingTool = .arrow
    @ObservedObject private var settings = SettingsStore.shared
    @State private var text = ""
    @State private var textSize: Double = 0.045
    @State private var brushWidth: Double = 0.08
    @State private var showTemplates = false
    @State private var showText = false
    @State private var isSaving = false
    @State private var saveError = false

    private var annotationColor: Color {
        switch settings.annotationColor {
        case "yellow": return .yellow
        case "white": return .white
        case "black": return .black
        default: return .red
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 8) {
                ZoomAnnotationCanvas(image: image, shapes: $shapes,
                                     tool: tool, color: annotationColor, text: text,
                                     brushWidth: CGFloat(brushWidth), textSize: CGFloat(textSize))
                    .overlay { if isSaving { ProgressView().tint(.orange) } }
                    .allowsHitTesting(!isSaving)
                if tool == .blur {
                    HStack {
                        Text("Кисть")
                        Slider(value: $brushWidth, in: 0.015...0.2)
                    }.padding(.horizontal)
                }
                Text(tool == .text
                     ? "Коснитесь фото для надписи. Перетащите её пальцем, измените размер щипком."
                     : "Один палец — пометки, два пальца — масштаб и перемещение фото.")
                    .font(.caption).foregroundColor(.secondary).padding(.horizontal)
                HStack(spacing: 8) {
                    toolButton("arrow.up.right", .arrow, "Стрелка")
                    toolButton("oval", .oval, "Овал")
                    Button {
                        let wasSelected = tool == .text
                        tool = .text
                        if wasSelected || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            showText = true
                        }
                    } label: { toolTile("textformat", title: "Текст", selected: tool == .text) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Текст на фото")
                    toolButton("eye.slash", .blur, "Размытие")
                }
                .padding(.horizontal, 12)
                HStack(spacing: 8) {
                    if addWatermark {
                        Button {
                            showTemplates = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "text.badge.plus")
                                Text(templates.selected.isEmpty ? "Шаблон подписи" : "Шаблон: \(templates.selected)")
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .accessibilityLabel("Выбрать шаблон подписи для следующих фото")
                    }
                    Spacer(minLength: 0)
                    Button { if !shapes.isEmpty { shapes.removeLast() } } label: {
                        Label("Отменить", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(minWidth: 96, minHeight: 52)
                            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(shapes.isEmpty)
                    .accessibilityLabel("Отменить последнюю пометку")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
            .background(Color.black)
            .foregroundColor(.white)
            .disabled(isSaving)
            .navigationTitle("Редактор")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Отмена", action: onCancel).disabled(isSaving) }
                ToolbarItem(placement: .navigationBarTrailing) { Button("Сохранить", action: save).disabled(isSaving) }
            }
        }
        .sheet(isPresented: $showTemplates) { LabelTemplateSheet(store: templates) }
        .sheet(isPresented: $showText) {
            NavigationView {
                Form {
                    Section("Текст на фото") { TextEditor(text: $text).frame(minHeight: 130) }
                    Section("Размер текста") { Slider(value: $textSize, in: 0.02...0.12) }
                    Text("После закрытия коснитесь нужного места на снимке. Повторное касание добавляет ещё одну надпись; кнопка отмены удаляет последнюю.")
                }
                .navigationTitle("Надпись")
                .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Готово") { showText = false } } }
            }
        }
        .alert("Не удалось сохранить фото", isPresented: $saveError) {
            Button("Закрыть", role: .cancel) {}
        } message: { Text("Пометки остались в редакторе. Проверьте свободное место и повторите сохранение.") }
    }

    private func toolButton(_ icon: String, _ value: DrawingTool, _ label: String) -> some View {
        Button { tool = value } label: { toolTile(icon, title: label, selected: tool == value) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }
    private func toolTile(_ icon: String, title: String, selected: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 27, weight: .semibold))
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundColor(selected ? .orange : .white)
        .frame(maxWidth: .infinity, minHeight: 76)
        .background(selected ? Color.orange.opacity(0.24) : Color.white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selected ? Color.orange : Color.clear, lineWidth: 2)
        }
        .contentShape(Rectangle())
    }
    private func save() {
        guard !isSaving else { return }
        isSaving = true
        let original = image
        let annotations = shapes
        let label = templates.selected.isEmpty ? nil : templates.selected
        let watermark = addWatermark
        let loc = location, hdg = heading
        let epoch = accessGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let base = watermark ? WatermarkRenderer.apply(to: original, location: loc, heading: hdg, labelText: label) : original
            let result = annotations.isEmpty ? base : AnnotationRenderer.render(image: base, shapes: annotations)
            DispatchQueue.main.async {
                guard (try? VaultGate.shared.withAccess(generation: epoch) { true }) == true else {
                    isSaving = false; saveError = true; return
                }
                onSave(result) { saved in
                    DispatchQueue.main.async {
                        isSaving = false
                        if !saved { saveError = true }
                    }
                }
            }
        }
    }
}

struct LabelTemplateSheet: View {
    @ObservedObject var store: LabelTemplatesStore
    @Environment(\.dismiss) var dismiss
    @State private var newTemplate = ""
    var body: some View {
        NavigationView {
            List {
                Section {
                    Button("Отключить подпись") { store.selected = ""; dismiss() }
                    ForEach(store.templates, id: \.self) { template in
                        Button {
                            store.selected = template; dismiss()
                        } label: {
                            HStack {
                                Text(template)
                                Spacer()
                                if store.selected == template { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    .onDelete { offsets in
                        store.templates.remove(atOffsets: offsets)
                        if !store.templates.contains(store.selected) { store.selected = "" }
                    }
                }
                Section("Новый шаблон") {
                    TextField("Подпись", text: $newTemplate)
                    Button("Добавить") {
                        let value = newTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty else { return }
                        if !store.templates.contains(value) { store.templates.append(value) }
                        store.selected = value; dismiss()
                    }
                }
            }
            .navigationTitle("Подписи")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Готово") { dismiss() } } }
        }
    }
}
