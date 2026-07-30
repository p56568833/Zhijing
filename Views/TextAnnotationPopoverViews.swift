import SwiftUI

struct TextAnnotationComposerView: View {
    let selectedText: String
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label("添加批注", systemImage: "text.bubble")
                    .font(.headline)
                Spacer()
                Text("⇧⌘M")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Text(selectedText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextField("写给自己和 AI 的批注…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...5)
                .focused($isFocused)
                .onSubmit(submit)
                .padding(9)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text("回车保存 · Esc 取消")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedText.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { isFocused = true }
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !trimmedText.isEmpty else { return }
        onSave(trimmedText)
    }
}

struct TextAnnotationDetailView: View {
    let annotation: TextAnnotation
    let onSave: (String) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(
        annotation: TextAnnotation,
        onSave: @escaping (String) -> Void,
        onDelete: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.annotation = annotation
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _text = State(initialValue: annotation.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("批注", systemImage: "text.bubble.fill")
                .font(.headline)
            Text(annotation.anchor.selectedText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextField("批注内容", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...6)
                .focused($isFocused)
                .onSubmit(submit)
                .padding(9)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("删除", role: .destructive) {
                    onDelete()
                }
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedText.isEmpty || trimmedText == annotation.text)
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { isFocused = true }
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !trimmedText.isEmpty else { return }
        onSave(trimmedText)
    }
}
