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
    @AppStorage("sidebarLibraryViewMode")
    private var libraryViewModeRaw: String = LibraryViewMode.tree.rawValue
    @AppStorage("sidebarCollapsedFolderPaths")
    private var collapsedFoldersJSON: String = "[]"
    @AppStorage("sidebarFolderOrder")
    private var folderOrderJSON: String = "{}"
    @State private var draggingDocumentPath: String?
    @State private var dragGhostOffset: CGFloat = 0
    @State private var dragGhostBaseOffset: CGFloat = 0
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

    private enum LibraryViewMode: String {
        case tree
        case list
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
                    if libraryViewMode == .tree {
                        libraryRootBar
                        selectionBreadcrumb
                    }
                    libraryToolbar
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
            if libraryViewMode == .tree, let folder = store.selectedDocument?.folder {
                expandFolderChain(for: folder)
            }
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

    private var libraryToolbar: some View {
        HStack(spacing: 6) {
            Picker("视图", selection: Binding(
                get: { libraryViewMode },
                set: { libraryViewModeRaw = $0.rawValue }
            )) {
                Label("树", systemImage: "folder").tag(LibraryViewMode.tree)
                Label("列表", systemImage: "list.bullet").tag(LibraryViewMode.list)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("文件树按文件夹组织文稿；列表保留手动拖动排序")
            if libraryViewMode == .list {
                scopePicker
                sortPicker
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.bottom, 8)
    }

    private var libraryRootBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let root = store.libraryURL {
                Text(abbreviatedRootPath(root))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(root.path)
                Button {
                    store.revealFolderInFinder("")
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.plain)
                .help("在 Finder 中显示知识库")
                Button {
                    store.copyFolderPathToPasteboard("")
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("拷贝知识库路径")
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var selectionBreadcrumb: some View {
        Group {
            if let document = store.selectedDocument {
                HStack(spacing: 3) {
                    Text("当前位置")
                        .foregroundStyle(.tertiary)
                    let parts = document.folder.isEmpty
                        ? []
                        : document.folder.split(separator: "/").map(String.init)
                    ForEach(parts.indices, id: \.self) { index in
                        Text("›").foregroundStyle(.tertiary)
                        Text(parts[index])
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text("›").foregroundStyle(.tertiary)
                    Text(document.title)
                        .foregroundStyle(.primary)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
                .font(.caption2)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func abbreviatedRootPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let raw = url.path
        return raw.hasPrefix(home) ? "~" + raw.dropFirst(home.count) : raw
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
                if libraryViewMode == .tree {
                    libraryTreeList
                } else {
                    documentsList
                }
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
                        // 被拖行的原位隐身，充当占位空隙；真实外观由浮层负责
                        .opacity(isDragged ? 0 : 1)
                        .animation(.snappy(duration: 0.26), value: orderSignature)
                    }
                }
                .overlay(alignment: .top) {
                    dragGhost
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, 8)
                .gesture(reorderGesture())
            }
        }
        .coordinateSpace(name: "libraryListSpace")
        .onPreferenceChange(RowFrameKey.self) { rowFrames = $0 }
    }

    /// 跟随指针的浮层行：位置 = 原槽位 + 纯指针位移。
    /// 它不参与布局，换位时其余行怎么动都影响不到它。
    @ViewBuilder
    private var dragGhost: some View {
        if let path = draggingDocumentPath,
           let document = displayDocuments.first(where: { $0.relativePath == path }) {
            LibraryRowContainer(
                isSelected: store.selectedDocument?.id == document.id
            ) {
                noteRow(document)
            }
            .scaleEffect(1.04)
            .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
            .offset(y: dragGhostBaseOffset + dragGhostOffset)
            .allowsHitTesting(false)
            .animation(.snappy(duration: 0.18), value: draggingDocumentPath == nil)
        }
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

    private var libraryViewMode: LibraryViewMode {
        LibraryViewMode(rawValue: libraryViewModeRaw) ?? .tree
    }

    private var folderOrder: [String: [String]] {
        (try? JSONDecoder().decode(
            [String: [String]].self,
            from: Data(folderOrderJSON.utf8)
        )) ?? [:]
    }

    private func setFolderOrder(_ value: [String: [String]]) {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else { return }
        folderOrderJSON = json
    }

    /// 同级文件夹的展示顺序：先按用户自定义排序，没排过的按名称跟在后面。
    private func effectiveFolderOrder(parent: String, siblings: [String]) -> [String] {
        let saved = (folderOrder[parent] ?? []).filter { siblings.contains($0) }
        let rest = siblings.filter { !saved.contains($0) }
        return saved + rest
    }

    private var collapsedFolders: Set<String> {
        Set((try? JSONDecoder().decode(
            [String].self,
            from: Data(collapsedFoldersJSON.utf8)
        )) ?? [])
    }

    private func setCollapsedFolders(_ value: Set<String>) {
        guard let data = try? JSONEncoder().encode(value.sorted()),
              let json = String(data: data, encoding: .utf8) else { return }
        collapsedFoldersJSON = json
    }

    private func toggleFolderCollapsed(_ path: String) {
        var collapsed = collapsedFolders
        if collapsed.contains(path) {
            collapsed.remove(path)
        } else {
            collapsed.insert(path)
        }
        setCollapsedFolders(collapsed)
    }

    /// 当前文稿所在文件夹及其祖先全部展开，保证选中行可见。
    /// 外部文稿的 folder 是绝对路径，不在知识库树里，直接跳过；
    /// 循环要求父路径严格缩短，防止根目录 `"/"` 的父目录仍是 `"/"` 导致死循环。
    private func expandFolderChain(for folder: String) {
        guard !folder.hasPrefix("/") else { return }
        var collapsed = collapsedFolders
        var current = folder
        while !current.isEmpty {
            collapsed.remove(current)
            let parent = (current as NSString).deletingLastPathComponent
            guard parent != current, parent != "." else { break }
            current = parent
        }
        setCollapsedFolders(collapsed)
    }

    private var libraryTreeList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if !store.favoriteDocuments.isEmpty {
                    treeSectionHeader(
                        "star",
                        "收藏",
                        store.favoriteDocuments.count
                    )
                    ForEach(sorted(store.favoriteDocuments)) { document in
                        LibraryRowContainer(
                            isSelected: store.selectedDocument?.id == document.id
                        ) {
                            noteRow(document)
                        }
                        .padding(.horizontal, 6)
                    }
                }
                treeSectionHeader("folder", "知识库", store.documents.count)
                treeRows(store.libraryTree, parent: "", depth: 0)
            }
            .padding(.horizontal, 6)
            .padding(.top, 2)
            .padding(.bottom, 8)
        }
    }

    private func treeSectionHeader(
        _ systemImage: String,
        _ title: String,
        _ count: Int
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10))
            Text(title)
            Text("\(count)")
                .foregroundStyle(.tertiary)
                .fontWeight(.regular)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 10)
        .padding(.top, 9)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // 递归树行：返回类型必须具体化（AnyView），否则 opaque 类型自指无法编译。
    private func treeRows(
        _ items: [LibraryTreeItem],
        parent: String,
        depth: Int
    ) -> AnyView {
        // 文件夹按用户自定义顺序排，文稿跟在后面。
        let savedOrder = folderOrder[parent] ?? []
        func rank(_ path: String) -> Int {
            savedOrder.firstIndex(of: path) ?? Int.max
        }
        let folders = items.compactMap { item -> LibraryTreeItem? in
            if case .folder = item.content { return item } else { return nil }
        }
        let documents = items.filter { item in
            if case .folder = item.content { return false } else { return true }
        }
        let sortedFolders = folders.sorted { a, b in
            guard case .folder(let pathA) = a.content,
                  case .folder(let pathB) = b.content else { return false }
            let rankA = rank(pathA), rankB = rank(pathB)
            if rankA != rankB { return rankA < rankB }
            return folderDisplayName(pathA)
                .localizedStandardCompare(folderDisplayName(pathB))
                == .orderedAscending
        }
        let orderedItems = sortedFolders + documents
        let siblingPaths = orderedItems.compactMap { item -> String? in
            if case .folder(let path) = item.content { return path } else { return nil }
        }

        return AnyView(
            ForEach(orderedItems, id: \.self) { item in
                switch item.content {
                case .folder(let path):
                    folderTreeRow(
                        item,
                        path: path,
                        parent: parent,
                        siblings: siblingPaths,
                        depth: depth
                    )
                case .document(let document):
                    LibraryRowContainer(
                        isSelected: store.selectedDocument?.id == document.id
                    ) {
                        noteRow(document)
                    }
                    .padding(.leading, CGFloat(depth) * 14 + 8)
                }
            }
        )
    }

    @ViewBuilder
    private func folderTreeRow(
        _ item: LibraryTreeItem,
        path: String,
        parent: String,
        siblings: [String],
        depth: Int
    ) -> some View {
        let isCollapsed = collapsedFolders.contains(path)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                Image(systemName: isCollapsed ? "folder" : "folder.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(folderDisplayName(path))
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(documents(in: path).count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, CGFloat(depth) * 14 + 8)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture { toggleFolderCollapsed(path) }
            .contextMenu { folderContextMenu(path, parent: parent, siblings: siblings) }
            .help(store.libraryURL?
                .appending(path: path, directoryHint: .isDirectory)
                .path ?? path)
            if !isCollapsed, let children = item.children {
                treeRows(children, parent: path, depth: depth + 1)
                    .padding(.leading, 13)
                    .overlay(alignment: .topLeading) {
                        Rectangle()
                            .fill(ZhijingTheme.hairline)
                            .frame(width: 1)
                            .padding(.leading, CGFloat(depth) * 14 + 15)
                    }
            }
        }
    }

    private func folderContextMenu(
        _ path: String,
        parent: String,
        siblings: [String]
    ) -> some View {
        Group {
            Button("上移") {
                moveFolder(path, parent: parent, siblings: siblings, offset: -1)
            }
            Button("下移") {
                moveFolder(path, parent: parent, siblings: siblings, offset: 1)
            }
            Divider()
            Button("在 Finder 中显示") { store.revealFolderInFinder(path) }
            Button("拷贝文件夹路径") { store.copyFolderPathToPasteboard(path) }
            Divider()
            Button("移到废纸篓", role: .destructive) {
                deleteFolderTarget = path
            }
        }
    }

    /// 在同级里把文件夹上移/下移一位，顺序持久化保存。
    private func moveFolder(
        _ path: String,
        parent: String,
        siblings: [String],
        offset: Int
    ) {
        var order = effectiveFolderOrder(parent: parent, siblings: siblings)
        guard let index = order.firstIndex(of: path) else { return }
        let target = index + offset
        guard siblings.indices.contains(target) else { return }
        order.remove(at: index)
        order.insert(path, at: target)
        var all = folderOrder
        all[parent] = order
        setFolderOrder(all)
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

    // MARK: - 拖拽排序（Safari 式：浮层跟手 + 原位空隙让位）

    /// 拖拽期间渲染冻结的本地顺序，松手才一次性提交回 store；
    /// 拖动途中排序基准（改动时间、外部文件变动）不会让列表在指下重排。
    private var displayDocuments: [NoteDocument] {
        dragActiveOrder ?? scopedDocuments
    }

    private func document(at point: CGPoint) -> NoteDocument? {
        scopedDocuments.first { document in
            guard let frame = rowFrames[document.relativePath] else { return false }
            return point.y >= frame.minY && point.y <= frame.maxY
        }
    }

    /// 列表级拖拽手势：起点落在哪一行就拖哪行。
    /// 手势挂在列表容器上——容器本身在拖拽期间永远不动，
    /// translation 始终是纯指针位移，从根上杜绝"行跟着指针走、
    /// 指针位移又被行移动污染"造成的乱飞。
    private func reorderGesture() -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("libraryListSpace"))
            .onChanged { value in
                guard renameTargetRowKey == nil else { return }
                if dragActiveOrder == nil {
                    // 槽位判定只认按下瞬间的静止布局快照：
                    // 此后邻居在滑动、浮层在飘，实时帧会污染基准。
                    let documents = scopedDocuments
                    guard !documents.isEmpty,
                          documents.allSatisfy({ rowFrames[$0.relativePath] != nil }),
                          let document = document(at: value.startLocation),
                          let frame = rowFrames[document.relativePath],
                          let firstFrame = rowFrames[documents[0].relativePath]
                    else { return }
                    draggingDocumentPath = document.relativePath
                    dragStartMidY = frame.midY
                    dragSlotMidYs = documents.map { rowFrames[$0.relativePath]!.midY }
                    // 浮层自然停靠在列表顶端，先补上"到原槽位"的位移
                    dragGhostBaseOffset = frame.minY - firstFrame.minY
                    dragGhostOffset = 0
                    dragActiveOrder = documents
                    dragMovedAny = false
                    NSCursor.closedHand.push()
                }
                guard let startMidY = dragStartMidY,
                      let visible = dragActiveOrder,
                      let draggedPath = draggingDocumentPath,
                      let index = visible.firstIndex(where: {
                          $0.relativePath == draggedPath
                      }),
                      !dragSlotMidYs.isEmpty,
                      index < dragSlotMidYs.count
                else { return }

                // 跟手，但夹在首尾槽位中线之间：行拖不出列表。
                let visualMidY = min(
                    max(startMidY + value.translation.height, dragSlotMidYs.first!),
                    dragSlotMidYs.last!
                )
                dragGhostOffset = visualMidY - startMidY

                // 中线越过哪个槽位就换到哪，可一次跨多格；
                // 换位只动数据，其余行靠签名动画弹簧滑动，浮层不受影响。
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
                dragActiveOrder = DocumentOrdering.moved(
                    visible, fromIndex: index, toIndex: target
                )
                dragMovedAny = true
            }
            .onEnded { _ in
                finishDrag()
            }
    }

    /// 松手：顺序一次性提交回 store，浮层从指针处弹回空隙槽位；
    /// 真实行保持隐身，等浮层落稳后再显形，位置逐像素相同。
    private func finishDrag() {
        guard let activeOrder = dragActiveOrder,
              let draggedPath = draggingDocumentPath,
              let startMidY = dragStartMidY,
              let index = activeOrder.firstIndex(where: { $0.relativePath == draggedPath }),
              !dragSlotMidYs.isEmpty,
              index < dragSlotMidYs.count
        else { return }
        NSCursor.pop()
        let moved = dragMovedAny
        dragMovedAny = false
        dragActiveOrder = nil
        dragStartMidY = nil
        if moved {
            if store.documentSort != .manual { store.documentSort = .manual }
            store.setManualDocumentOrder(activeOrder)
        }
        let landingOffset = dragSlotMidYs[index] - startMidY
        dragSlotMidYs = []
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            dragGhostOffset = landingOffset
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.42))
            if draggingDocumentPath == draggedPath, dragActiveOrder == nil {
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
