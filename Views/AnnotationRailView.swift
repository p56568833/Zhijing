import SwiftUI

struct AnnotationRailView: View {
    let documentTitle: String
    let items: [TextAnnotationDisplayItem]
    let composerRequest: AnnotationComposerRequest?
    let onCreate: (String, EditorTextSelection) -> Void
    let onCancelComposer: () -> Void
    let onReveal: (UUID) -> Void
    let onUpdate: (UUID, String) -> Void
    let onToggleResolved: (UUID) -> Void
    let onRelink: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onClose: () -> Void

    @State private var filter: AnnotationRailFilter = .open
    @State private var selectedID: UUID?
    @State private var pendingDeletion: TextAnnotationDisplayItem?

    private var filteredItems: [TextAnnotationDisplayItem] {
        items.filter(filter.includes)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.65)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if let composerRequest {
                            AnnotationComposerCard(
                                request: composerRequest,
                                onSave: { onCreate($0, composerRequest.selection) },
                                onCancel: onCancelComposer
                            )
                            .id(composerRequest.id)
                            .padding(.horizontal, 14)
                            .padding(.top, 14)
                            .padding(.bottom, filteredItems.isEmpty ? 14 : 8)
                        }

                        if filteredItems.isEmpty, composerRequest == nil {
                            emptyState
                                .padding(.horizontal, 22)
                                .padding(.vertical, 36)
                        } else {
                            ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                                AnnotationCardView(
                                    number: displayNumber(for: item, fallback: index + 1),
                                    item: item,
                                    isSelected: selectedID == item.id,
                                    onReveal: {
                                        selectedID = item.id
                                        onReveal(item.id)
                                    },
                                    onUpdate: { onUpdate(item.id, $0) },
                                    onToggleResolved: { onToggleResolved(item.id) },
                                    onRelink: { onRelink(item.id) },
                                    onDelete: { pendingDeletion = item }
                                )
                                .id(item.id)
                            }
                        }
                    }
                    .padding(.bottom, 16)
                }
                .onChange(of: selectedID) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
                .onChange(of: composerRequest?.id) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(newValue, anchor: .top)
                    }
                }
            }
            Divider().opacity(0.65)
            syncFooter
        }
        .frame(minWidth: 270, idealWidth: 300, maxWidth: 380)
        .background(.bar)
        .alert(
            "删除这条批注？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { item in
            Button("删除", role: .destructive) {
                onDelete(item.id)
                if selectedID == item.id { selectedID = nil }
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { _ in
            Text("正文不会变化，外部 AI 使用的批注文件会同步更新。")
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "text.bubble")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 1) {
                Text("批注")
                    .font(.system(size: 13, weight: .semibold))
                Text(headerSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button(action: revealPrevious) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(filteredItems.isEmpty)
            .help("上一条批注")

            Button(action: revealNext) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(filteredItems.isEmpty)
            .help("下一条批注")

            Menu {
                Picker("筛选批注", selection: $filter) {
                    ForEach(AnnotationRailFilter.allCases) { option in
                        Label(option.title, systemImage: option.systemImage)
                            .tag(option)
                    }
                }
            } label: {
                Image(systemName: filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("筛选批注")

            Button(action: onClose) {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.plain)
            .help("隐藏批注栏")
        }
        .controlSize(.small)
        .padding(.horizontal, 13)
        .frame(height: 50)
        .accessibilityLabel("\(documentTitle) 的文档批注")
    }

    private var syncFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
            Text("已同步到 AI 可读取的批注文件")
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .help("知识库中的 ZHJING_COMMENTS.md 会保存正文引用和批注内容")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: filter == .open ? "checkmark.bubble" : "text.bubble")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(filter == .open && !items.isEmpty ? "没有待处理批注" : "还没有批注")
                .font(.callout.weight(.medium))
            Text(filter == .open && !items.isEmpty
                 ? "已处理的内容可以在筛选菜单中查看。"
                 : "选中正文后点旁边的批注图标，或按 ⇧⌘M。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var headerSummary: String {
        if composerRequest != nil { return "正在添加新批注" }
        let openCount = items.lazy.filter { !$0.annotation.isResolved }.count
        if items.isEmpty { return "选择正文即可添加" }
        if openCount == 0 { return "\(items.count) 条，全部已处理" }
        return "\(openCount) 条待处理 · 共 \(items.count) 条"
    }

    private func displayNumber(
        for item: TextAnnotationDisplayItem,
        fallback: Int
    ) -> Int {
        items.firstIndex(where: { $0.id == item.id }).map { $0 + 1 } ?? fallback
    }

    private func revealPrevious() {
        reveal(offset: -1)
    }

    private func revealNext() {
        reveal(offset: 1)
    }

    private func reveal(offset: Int) {
        guard !filteredItems.isEmpty else { return }
        let currentIndex = selectedID.flatMap { id in
            filteredItems.firstIndex(where: { $0.id == id })
        }
        let nextIndex: Int
        if let currentIndex {
            nextIndex = (currentIndex + offset + filteredItems.count) % filteredItems.count
        } else {
            nextIndex = offset < 0 ? filteredItems.count - 1 : 0
        }
        let item = filteredItems[nextIndex]
        selectedID = item.id
        onReveal(item.id)
    }
}

private enum AnnotationRailFilter: String, CaseIterable, Identifiable {
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

private struct AnnotationComposerCard: View {
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

private struct AnnotationCardView: View {
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
