import AppKit
import SwiftUI

/// 文库列表行帧测量用的偏好键，拖拽排序时用它定位落点。
private struct RowFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// 文库列表的行容器：负责选中与悬停的圆角高亮（替代 List 的样式）。
private struct LibraryRowContainer<Content: View>: View {
    let isSelected: Bool
    @ViewBuilder let content: () -> Content
    @State private var isHovering = false

    var body: some View {
        content()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isSelected
                            ? ZhijingTheme.accent.opacity(0.16)
                            : isHovering ? Color.primary.opacity(0.05) : Color.clear
                    )
            )
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.1), value: isHovering)
    }
}

struct SidebarView: View {
    @Bindable var store: AppStore
    @State private var contentMode = SidebarContentMode.library
    @State private var outlineItems: [DocumentOutlineItem] = []
    @State private var selectedOutlineItemID: String?
    @State private var renameText = ""
    @State private var deleteTarget: NoteDocument?
    @State private var renameTargetRowKey: String?
    @State private var deleteFolderTarget: String?
    @State private var libraryScope: LibraryScope = .all
    @State private var draggingDocumentPath: String?
    @State private var dragOffset: CGFloat = 0
    @State private var dragStartMidY: CGFloat?
    @State private var dragSlotMidYs: [CGFloat] = []
    @State private var dragActiveOrder: [NoteDocument]?
    @State private var dragMovedAny = false
    @State private var rowFrames: [String: CGRect] = [:]
    @FocusState private var renameFocus: RenameFocus?

    private enum LibraryScope: Hashable {
        case all
        case favorites
        case folder(String)
    }

    private enum RenameFocus: Hashable {
        case document(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            contentModePicker
            switch contentMode {
            case .library:
                searchBar
                if store.searchQuery.isEmpty {
                    scopeAndSortBar
                }
            case .outline:
                outlineHeader
            }
            Divider().opacity(0.58)
            switch contentMode {
            case .library:
                libraryList
            case .outline:
                documentOutline
            }
            Divider().opacity(0.58)
            statusBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ZhijingTheme.sidebar)
        .animation(.snappy(duration: 0.24), value: contentMode)
        .task(id: outlineRefreshID) {
            await refreshOutline()
        }
        .onChange(of: store.selectedDocument?.id) { _, _ in
            selectedOutlineItemID = nil
        }
        .confirmationDialog(
            "要将“\(deleteTarget?.title ?? "")”移到废纸篓吗？",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            Button("移到废纸篓", role: .destructive) {
                if let deleteTarget { store.delete(deleteTarget) }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        }
        .confirmationDialog(
            "要将文件夹“\(deleteFolderTargetTitle)”移到废纸篓吗？",
            isPresented: Binding(
                get: { deleteFolderTarget != nil },
                set: { if !$0 { deleteFolderTarget = nil } }
            )
        ) {
            Button("移到废纸篓", role: .destructive) {
                if let deleteFolderTarget {
                    store.deleteFolder(deleteFolderTarget)
                }
                deleteFolderTarget = nil
            }
            Button("取消", role: .cancel) { deleteFolderTarget = nil }
        } message: {
            Text("其中的所有文件（含 \(documents(in: deleteFolderTarget ?? "").count) 篇文稿）也会一起移入废纸篓。")
        }
    }

    private var deleteFolderTargetTitle: String {
        folderDisplayName(deleteFolderTarget ?? "")
    }

    private var contentModePicker: some View {
        Picker("侧栏内容", selection: $contentMode) {
            Label("文库", systemImage: "books.vertical")
                .tag(SidebarContentMode.library)
            Label("大纲", systemImage: "list.bullet.indent")
                .tag(SidebarContentMode.outline)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索文件名与正文", text: $store.searchQuery)
                .textFieldStyle(.plain)
                .onSubmit { store.performSearch() }
                .onChange(of: store.searchQuery) { _, _ in store.performSearch() }
            if !store.searchQuery.isEmpty {
                Button {
                    store.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var scopeAndSortBar: some View {
        HStack(spacing: 6) {
            scopePicker
            sortPicker
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.bottom, 8)
    }

    private var scopePicker: some View {
        Picker("文稿范围", selection: $libraryScope) {
            Text("全部文稿").tag(LibraryScope.all)
            Text("收藏").tag(LibraryScope.favorites)
            ForEach(sortedFolders, id: \.self) { folder in
                Text(folderDisplayName(folder)).tag(LibraryScope.folder(folder))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sortPicker: some View {
        Picker("排序", selection: $store.documentSort) {
            ForEach(AppDocumentSort.allCases, id: \.self) { sort in
                Text(sort.label).tag(sort)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .help("拖动文稿行可手动调换顺序")
    }

    private var libraryList: some View {
        Group {
            if store.searchQuery.isEmpty {
                documentsList
            } else {
                searchResultsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var documentsList: some View {
        let documents = displayDocuments
        let orderSignature = documents
            .map(\.relativePath)
            .joined(separator: "\u{2028}")
        return ScrollView {
            if documents.isEmpty {
                emptyScopeView
                    .padding(.top, 44)
                    .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 0) {
                    ForEach(documents) { document in
                        let isDragged = draggingDocumentPath == document.relativePath
                        LibraryRowContainer(
                            isSelected: store.selectedDocument?.id == document.id
                        ) {
                            noteRow(document)
                        }
                        .background(frameReader(for: document))
                        .scaleEffect(isDragged ? 1.04 : 1)
                        .offset(y: isDragged ? dragOffset : 0)
                        .zIndex(isDragged ? 1 : 0)
                        .shadow(
                            color: .black.opacity(isDragged ? 0.3 : 0),
                            radius: isDragged ? 14 : 0,
                            y: isDragged ? 6 : 0
                        )
                        .animation(.snappy(duration: 0.2), value: isDragged)
                        .animation(
                            isDragged ? nil : .snappy(duration: 0.26),
                            value: orderSignature
                        )
                        .gesture(reorderGesture(for: document))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
        }
        .coordinateSpace(name: "libraryListSpace")
        .onPreferenceChange(RowFrameKey.self) { rowFrames = $0 }
    }

    @ViewBuilder
    private var emptyScopeView: some View {
        switch libraryScope {
        case .favorites:
            Text("还没有收藏，右键文稿即可添加。")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .folder:
            Text("这个文件夹还没有文稿。")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .all:
            ContentUnavailableView(
                "知识库是空的",
                systemImage: "books.vertical",
                description: Text("点击左下角的“+”新建文稿。")
            )
        }
    }

    private var searchResultsList: some View {
        ScrollView {
            if store.searchResults.isEmpty {
                ContentUnavailableView.search(text: store.searchQuery)
                    .padding(.top, 44)
                    .frame(maxWidth: .infinity)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(store.searchResults) { hit in
                        LibraryRowContainer(isSelected: false) {
                            searchResultRow(hit)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)
            }
        }
    }

    private func searchResultRow(_ hit: SearchHit) -> some View {
        Button {
            store.select(hit.document, atLine: hit.line)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(hit.document.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(hit.excerpt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Text("\(hit.document.folder.isEmpty ? "知识库根目录" : hit.document.folder) · 第 \(hit.line) 行")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var scopedDocuments: [NoteDocument] {
        let filtered: [NoteDocument]
        switch libraryScope {
        case .all:
            filtered = store.documents
        case .favorites:
            filtered = store.favoriteDocuments
        case .folder(let folder):
            filtered = store.documents.filter {
                $0.folder == folder || $0.folder.hasPrefix(folder + "/")
            }
        }
        return sorted(filtered)
    }

    private func sorted(_ documents: [NoteDocument]) -> [NoteDocument] {
        let byPath = Dictionary(
            uniqueKeysWithValues: documents.map { ($0.relativePath, $0) }
        )
        switch store.documentSort {
        case .recent:
            return documents.sorted { $0.modifiedAt > $1.modifiedAt }
        case .title:
            return documents.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        case .manual:
            let orderedPaths = DocumentOrdering.applyingManualOrder(
                store.manualDocumentOrder,
                to: documents.map(\.relativePath)
            )
            return orderedPaths.compactMap { byPath[$0] }
        }
    }

    private var sortedFolders: [String] {
        store.folders.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var outlineHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(store.selectedDocument?.title ?? "未选择文稿")
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text("\(store.documentWordCount.formatted()) 字")
                Circle()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 3, height: 3)
                Text("\(outlineItems.count) 个标题")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var documentOutline: some View {
        if store.selectedDocument == nil {
            DocumentOutlineEmptyState(isSubtitle: false) {
                contentMode = .library
            }
        } else if outlineItems.isEmpty {
            DocumentOutlineEmptyState(isSubtitle: selectedDocumentIsSubtitle) {
                withAnimation(.snappy(duration: 0.22)) {
                    contentMode = .library
                }
            }
        } else {
            DocumentOutlineNavigationView(
                items: outlineItems,
                selectedItemID: selectedOutlineItemID
            ) { item in
                withAnimation(.snappy(duration: 0.2)) {
                    selectedOutlineItemID = item.id
                }
                store.navigateToOutlineItem(item)
            }
        }
    }

    private var statusBar: some View {
        HStack {
            if contentMode == .outline {
                Text(outlineItems.isEmpty ? "等待标题" : "点击标题快速定位")
            } else if store.isIndexing {
                ProgressView().controlSize(.small)
                Text("正在更新索引")
            } else {
                Text("\(store.documents.count) 篇文稿")
            }
            Spacer()
            if contentMode == .outline {
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        contentMode = .library
                    }
                } label: {
                    Image(systemName: "books.vertical")
                }
                .buttonStyle(.plain)
                .help("返回文库")
            } else {
                Menu {
                    Button("新建文稿", systemImage: "doc.badge.plus") { store.createNote() }
                    Button("新建文件夹", systemImage: "folder.badge.plus") { store.createFolder() }
                    Divider()
                    Button("更换知识库…") { store.chooseLibrary() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private var outlineRefreshID: String {
        "\(store.selectedDocument?.id ?? "none"):\(store.editorContentRevision)"
    }

    private func refreshOutline() async {
        guard let documentID = store.selectedDocument?.id else {
            outlineItems = []
            return
        }
        let source = store.editorText
        let parsed = await Task.detached(priority: .userInitiated) {
            DocumentOutlineParser.parse(source)
        }.value
        guard !Task.isCancelled,
              store.selectedDocument?.id == documentID,
              store.editorText == source else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            outlineItems = parsed
            if let selectedOutlineItemID,
               !parsed.contains(where: { $0.id == selectedOutlineItemID }) {
                self.selectedOutlineItemID = nil
            }
        }
    }

    private var selectedDocumentIsSubtitle: Bool {
        store.selectedDocument?.url.pathExtension.lowercased() == "srt"
    }

    private func noteRow(_ document: NoteDocument) -> some View {
        HStack(spacing: 6) {
            if renameTargetRowKey == document.id {
                TextField("文稿名称", text: $renameText)
                    .textFieldStyle(.plain)
                    .focused($renameFocus, equals: .document(document.id))
                    .onSubmit { commitDocumentRename(document) }
                    .onExitCommand { cancelRename() }
            } else {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(document.title).lineLimit(1)
                        if !document.folder.isEmpty {
                            Text(document.folder)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } icon: {
                    Image(systemName: document.kindIcon)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if renameTargetRowKey != document.id {
                favoriteButton(document)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard renameTargetRowKey != document.id else { return }
            store.select(document)
        }
        .contextMenu {
            Button(store.favorites.contains(document.persistenceKey) ? "取消收藏" : "收藏") {
                store.toggleFavorite(document)
            }
            Button("重命名…") {
                beginRenaming(document)
            }
            moveToFolderMenu(document)
            Button("在 Finder 中显示") { store.revealInFinder(document) }
            Divider()
            Button("移到废纸篓", role: .destructive) { deleteTarget = document }
        }
    }

    // MARK: - 拖拽排序（Safari 式：按住浮起跟手，其余行让位，松手弹回槽位）

    /// 拖拽期间渲染冻结的本地顺序，松手才一次性提交回 store；
    /// 拖动途中排序基准（改动时间、外部文件变动）不会让列表在指下重排。
    private var displayDocuments: [NoteDocument] {
        dragActiveOrder ?? scopedDocuments
    }

    /// 手势驱动的拖拽排序：按下即浮起、1:1 跟手；
    /// 行的中线越过相邻槽位中线时其余行弹簧让位，可一次跨多格。
    private func reorderGesture(for document: NoteDocument) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                guard renameTargetRowKey == nil else { return }
                guard dragActiveOrder == nil
                    || draggingDocumentPath == document.relativePath else { return }
                if dragActiveOrder == nil {
                    // 槽位判定只认按下瞬间的静止布局快照：
                    // 此后邻居在滑动、被拖行在飘，实时帧会污染基准。
                    let documents = scopedDocuments
                    guard !documents.isEmpty,
                          documents.allSatisfy({ rowFrames[$0.relativePath] != nil })
                    else { return }
                    draggingDocumentPath = document.relativePath
                    dragStartMidY = rowFrames[document.relativePath]?.midY
                    dragSlotMidYs = documents.map { rowFrames[$0.relativePath]!.midY }
                    dragActiveOrder = documents
                    dragMovedAny = false
                    NSCursor.closedHand.push()
                }
                guard let startMidY = dragStartMidY,
                      let visible = dragActiveOrder,
                      let index = visible.firstIndex(where: {
                          $0.relativePath == document.relativePath
                      }),
                      !dragSlotMidYs.isEmpty,
                      index < dragSlotMidYs.count
                else { return }

                // 跟手，但夹在首尾槽位中线之间：行拖不出列表。
                let visualMidY = min(
                    max(startMidY + value.translation.height, dragSlotMidYs.first!),
                    dragSlotMidYs.last!
                )
                dragOffset = visualMidY - dragSlotMidYs[index]

                var target = index
                while target + 1 < dragSlotMidYs.count,
                      visualMidY > (dragSlotMidYs[target] + dragSlotMidYs[target + 1]) / 2 {
                    target += 1
                }
                while target > 0,
                      visualMidY < (dragSlotMidYs[target - 1] + dragSlotMidYs[target]) / 2 {
                    target -= 1
                }
                guard target != index else { return }
                // 换位写入本地顺序：其余行靠签名动画弹簧滑动，
                // 被拖行的槽位变化必须瞬时，才能和上面的跟手偏移严格抵消。
                dragActiveOrder = DocumentOrdering.moved(
                    visible, fromIndex: index, toIndex: target
                )
                dragOffset = visualMidY - dragSlotMidYs[target]
                dragMovedAny = true
            }
            .onEnded { _ in
                finishDrag()
            }
    }

    /// 松手：顺序一次性提交回 store，行从指针处弹回槽位；
    /// 浮起状态多留一拍再收，避免落位动画没走完就沉到邻行下面。
    private func finishDrag() {
        guard let activeOrder = dragActiveOrder else { return }
        NSCursor.pop()
        let draggedPath = draggingDocumentPath
        dragActiveOrder = nil
        dragStartMidY = nil
        dragSlotMidYs = []
        let moved = dragMovedAny
        dragMovedAny = false
        if moved {
            if store.documentSort != .manual { store.documentSort = .manual }
            store.setManualDocumentOrder(activeOrder)
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            dragOffset = 0
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.45))
            if draggingDocumentPath == draggedPath,
               dragActiveOrder == nil, dragOffset == 0 {
                draggingDocumentPath = nil
            }
        }
    }

    private func frameReader(for document: NoteDocument) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: RowFrameKey.self,
                value: [
                    document.relativePath: geo.frame(in: .named("libraryListSpace"))
                ]
            )
        }
    }

    private func favoriteButton(_ document: NoteDocument) -> some View {
        let isFavorite = store.favorites.contains(document.persistenceKey)
        return Button {
            store.toggleFavorite(document)
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.caption)
                .foregroundStyle(isFavorite ? Color.yellow : Color.secondary.opacity(0.55))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isFavorite ? "取消收藏" : "收藏")
    }

    private func moveToFolderMenu(_ document: NoteDocument) -> some View {
        Menu("移动到…") {
            Button("知识库根目录") {
                store.move(document, toFolder: "")
            }
            .disabled(document.folder.isEmpty)
            ForEach(
                sortedFolders.filter { $0 != document.folder },
                id: \.self
            ) { folder in
                Button(folderDisplayName(folder)) {
                    store.move(document, toFolder: folder)
                }
            }
        }
    }

    private func beginRenaming(_ document: NoteDocument) {
        renameTargetRowKey = document.id
        renameText = document.title
        DispatchQueue.main.async {
            renameFocus = .document(document.id)
        }
    }

    private func commitDocumentRename(_ document: NoteDocument) {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        cancelRename()
        store.rename(document, to: name)
    }

    private func cancelRename() {
        renameFocus = nil
        renameTargetRowKey = nil
        renameText = ""
    }

    private func folderDisplayName(_ folder: String) -> String {
        (folder as NSString).lastPathComponent
    }

    private func documents(in folder: String) -> [NoteDocument] {
        store.documents.filter {
            $0.folder == folder || $0.folder.hasPrefix(folder + "/")
        }
    }
}
