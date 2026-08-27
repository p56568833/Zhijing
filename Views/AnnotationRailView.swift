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
        .background(ZhijingTheme.sidebar)
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
            Text("正文不会变化，随文稿保存的批注文件会同步更新。")
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "text.bubble")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ZhijingTheme.annotation)

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
            Text("已同步到文稿批注文件")
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
