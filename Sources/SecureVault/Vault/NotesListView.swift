import SwiftUI

struct NotesListView: View {
    @ObservedObject private var manager = NotesManager.shared
    @Environment(\.dismiss) var dismiss
    @State private var notes: [Note] = []
    @State private var searchText = ""
    @State private var showEditor = false
    @State private var editingNote: Note?
    @State private var noteToDelete: Note?
    @State private var showDeleteConfirm = false

    private var filteredNotes: [Note] {
        guard !searchText.isEmpty else { return notes }
        return notes.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.content.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var pinnedNotes: [Note] {
        filteredNotes.filter { $0.isPinned }
    }

    private var unpinnedNotes: [Note] {
        filteredNotes.filter { !$0.isPinned }
    }

    var body: some View {
        NavigationView {
            List {
                if filteredNotes.isEmpty {
                    Text(searchText.isEmpty ? "Нет заметок" : "Ничего не найдено")
                        .foregroundColor(.secondary)
                } else {
                    if !pinnedNotes.isEmpty {
                        Section("Закреплённые") {
                            ForEach(pinnedNotes) { note in
                                noteRow(note)
                            }
                        }
                    }
                    Section(pinnedNotes.isEmpty ? "" : "Все заметки") {
                        ForEach(unpinnedNotes) { note in
                            noteRow(note)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Поиск по заметкам")
            .navigationTitle("Дневник")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Закрыть") { dismiss() }
                        .foregroundColor(.orange)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        editingNote = nil
                        showEditor = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundColor(.orange)
                    }
                }
            }
        }
        .onAppear { reload() }
        .sheet(isPresented: $showEditor, onDismiss: reload) {
            NoteEditorView(note: editingNote)
        }
        .alert("Удалить заметку?", isPresented: $showDeleteConfirm) {
            Button("Удалить", role: .destructive) {
                if let note = noteToDelete {
                    NotesManager.shared.delete(note)
                    reload()
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Это действие нельзя отменить.")
        }
        .alert("Дневник", isPresented: Binding(get: { manager.lastError != nil }, set: { if !$0 { manager.lastError = nil } })) {
            Button("Закрыть") { manager.lastError = nil }
        } message: { Text(manager.lastError ?? "") }
    }

    @ViewBuilder
    private func noteRow(_ note: Note) -> some View {
        Button {
            editingNote = note
            showEditor = true
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if note.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                    Text(note.title.isEmpty ? "Без названия" : note.title)
                        .font(.headline)
                        .foregroundColor(.primary)
                }
                if !note.content.isEmpty {
                    Text(note.content)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Text(formatDate(note.modifiedDate))
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                NotesManager.shared.togglePin(note)
                reload()
            } label: {
                Label(note.isPinned ? "Открепить" : "Закрепить",
                      systemImage: note.isPinned ? "pin.slash" : "pin")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                noteToDelete = note
                showDeleteConfirm = true
            } label: {
                Label("Удалить", systemImage: "trash")
            }
        }
    }

    private func reload() {
        let all = NotesManager.shared.loadAll()
        notes = all.sorted { $0.modifiedDate > $1.modifiedDate }
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM yyyy, HH:mm"
        return f.string(from: date)
    }
}

struct NoteEditorView: View {
    let note: Note?
    @Environment(\.dismiss) var dismiss
    @State private var title: String = ""
    @State private var content: String = ""
    @State private var isPinned: Bool = false
    @State private var saveError = false
    private let accessGeneration = VaultGate.shared.generation
    init(note: Note?) { self.note = note }

    var body: some View {
        NavigationView {
            Form {
                Section("Заголовок") {
                    TextField("Например: Пароли от Wi-Fi", text: $title)
                }
                Section("Текст") {
                    TextEditor(text: $content)
                        .frame(minHeight: 250)
                }
                if note != nil {
                    Section {
                        Toggle("Закрепить заметку", isOn: $isPinned)
                            .tint(.orange)
                    }
                }
            }
            .navigationTitle(note == nil ? "Новая заметка" : "Редактирование")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Отмена") { dismiss() }
                        .foregroundColor(.red)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Сохранить") { save() }
                        .foregroundColor(.orange)
                        .disabled(
                            title.trimmingCharacters(in: .whitespaces).isEmpty &&
                            content.trimmingCharacters(in: .whitespaces).isEmpty
                        )
                }
            }
        }
        .onAppear {
            if let note = note {
                title = note.title
                content = note.content
                isPinned = note.isPinned
            }
        }
        .alert("Заметка не сохранена", isPresented: $saveError) {
            Button("Закрыть") { NotesManager.shared.lastError = nil }
        } message: { Text(NotesManager.shared.lastError ?? "Повторите сохранение.") }
    }

    private func save() {
        let success: Bool
        if let existing = note {
            var updated = existing
            updated.title = title
            updated.content = content
            updated.isPinned = isPinned
            success = NotesManager.shared.update(updated, generation: accessGeneration)
        } else {
            success = NotesManager.shared.add(title: title, content: content, generation: accessGeneration)
        }
        if success { dismiss() } else { saveError = true }
    }
}
