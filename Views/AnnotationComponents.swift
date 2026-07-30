import SwiftUI

enum AnnotationRailFilter: String, CaseIterable, Identifiable {
    case open
    case all
    case orphaned

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: "待处理"
        case .all: "全部"
        case .orphaned: "需要关联"
        }
    }

    var systemImage: String {
        switch self {
        case .open: "circle"
        case .all: "text.bubble"
        case .orphaned: "link.badge.plus"
        }
    }

    func includes(_ item: TextAnnotationDisplayItem) -> Bool {
        switch self {
        case .open: !item.annotation.isResolved
        case .all: true
        case .orphaned: item.isOrphaned
        }
    }
}

struct AnnotationComposerCard: View {
    let request: AnnotationComposerRequest
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "plus.bubble")
                    .foregroundStyle(.orange)
                Text("新批注")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("取消")
            }

            QuotedTextView(text: request.selection.text, lineLimit: 3)

            TextEditor(text: $text)
                .font(.callout)
                .focused($isFocused)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .frame(minHeight: 88, maxHeight: 160)
                .background(
                    Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.primary.opacity(0.08))
                }
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("写下判断、问题或修改意图…")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                Text("⌘↩ 保存 · Esc 取消")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("保存", action: submit)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(trimmedText.isEmpty)
            }
        }
        .padding(13)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.orange.opacity(0.72))
                .frame(width: 3)
                .padding(.vertical, 10)
        }
        .shadow(color: Color.orange.opacity(0.07), radius: 10, y: 4)
        .onAppear {
            DispatchQueue.main.async {
                isFocused = true
            }
        }
        .onExitCommand(perform: onCancel)
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !trimmedText.isEmpty else { return }
        onSave(trimmedText)
    }
}

struct AnnotationCardView: View {
    let number: Int
    let item: TextAnnotationDisplayItem
    let isSelected: Bool
    let onReveal: () -> Void
    let onUpdate: (String) -> Void
    let onToggleResolved: () -> Void
    let onRelink: () -> Void
    let onDelete: () -> Void

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            connector

            VStack(alignment: .leading, spacing: 9) {
                cardHeader
                QuotedTextView(text: item.annotation.anchor.selectedText, lineLimit: 3)

                if isEditing {
                    editor
                } else {
                    Text(item.annotation.text)
                        .font(.callout)
                        .foregroundStyle(item.annotation.isResolved ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if item.isOrphaned {
                    orphanedNotice
                }
            }
            .padding(.vertical, 13)
            .padding(.leading, 10)
            .padding(.trailing, 13)
            .background(isSelected ? Color.orange.opacity(0.055) : .clear)
            .contentShape(Rectangle())
            .onTapGesture {
                if !isEditing, !item.isOrphaned { onReveal() }
            }
        }
        .padding(.horizontal, 8)
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.leading, 41)
                .opacity(0.55)
        }
        .accessibilityElement(children: .contain)
    }

    private var connector: some View {
        VStack(spacing: 5) {
            Circle()
                .fill(item.annotation.isResolved ? Color.secondary.opacity(0.28) : Color.orange.opacity(0.82))
                .frame(width: 7, height: 7)
            Rectangle()
                .fill(Color.orange.opacity(isSelected ? 0.5 : 0.18))
                .frame(width: 1)
        }
        .frame(width: 24)
        .padding(.top, 20)
    }

    private var cardHeader: some View {
        HStack(spacing: 7) {
            Text("\(number)")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(item.annotation.isResolved ? .tertiary : .secondary)
            if item.annotation.isResolved {
                Label("已处理", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else if item.isOrphaned {
                Label("需要关联", systemImage: "link.badge.plus")
                    .foregroundStyle(.orange)
            } else {
                Text("待处理")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button(item.annotation.isResolved ? "重新打开" : "标记为已处理") {
                    onToggleResolved()
                }
                Button("编辑批注") { beginEditing() }
                if item.isOrphaned {
                    Divider()
                    Button("关联到当前选区", action: onRelink)
                }
                Divider()
                Button("删除批注", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 22, height: 20)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .font(.caption)
    }

    private var editor: some View {
        VStack(spacing: 8) {
            TextEditor(text: $draft)
                .font(.callout)
                .focused($isEditorFocused)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 80, maxHeight: 150)
                .background(
                    Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 7)
                )
            HStack {
                Button("取消") { isEditing = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") { save() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(trimmedDraft.isEmpty)
            }
        }
    }

    private var orphanedNotice: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("原文已经变化，但这条批注仍会保留。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("关联到当前选区", action: onRelink)
                .buttonStyle(.link)
                .font(.caption)
                .help("先在正文中选中新的对应文字")
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func beginEditing() {
        draft = item.annotation.text
        isEditing = true
        isEditorFocused = true
    }

    private func save() {
        guard !trimmedDraft.isEmpty else { return }
        onUpdate(trimmedDraft)
        isEditing = false
    }
}

private struct QuotedTextView: View {
    let text: String
    let lineLimit: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.orange.opacity(0.42))
                .frame(width: 2)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(lineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
