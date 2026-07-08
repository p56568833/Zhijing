import SwiftUI

struct SidebarView: View {
    @Bindable var store: AppStore
    @State private var renameText = ""
    @State private var deleteTarget: NoteDocument?
    @State private var renameTargetRowKey: String?
    @State private var folderRenameTarget: String?
    @State private var deleteFolderTarget: String?
    @State private var libraryFilter = LibraryFilter.all
    @FocusState private var renameFocus: RenameFocus?

    private enum LibraryFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case favorites = "收藏"
        case recent = "最近"

        var id: Self { self }
    }

    private enum RenameFocus: Hashable {
        case document(String)
        case folder(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if store.searchQuery.isEmpty {
                libraryFilterPicker
            }
            Divider()
            if store.searchQuery.isEmpty {
                libraryList
            } else {
                searchResults
            }
            Divider()
            statusBar
        }
        .background(.regularMaterial)
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
            "要将文件夹“\(folderDisplayName(deleteFolderTarget ?? ""))”移到废纸篓吗？",
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
                    store.searchResults = []
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

    private var libraryFilterPicker: some View {
        Picker("文稿范围", selection: $libraryFilter) {
            ForEach(LibraryFilter.allCases) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 10)
        .padding(.bottom, 9)
    }

    private var libraryList: some View {
        List(selection: Binding(
            get: { store.selectedDocument?.id },
            set: { id in
                if let document = store.documents.first(where: { $0.id == id }) {
                    store.select(document)
                }
            }
        )) {
            switch libraryFilter {
            case .all:
                Section {
                    ForEach(store.folderGroups) { group in
                        if group.name.isEmpty {
                            ForEach(group.documents) { document in
                                noteRow(document, rowKey: document.id)
                                    .tag(document.id)
                            }
                        } else if group.documents.isEmpty {
                            folderRow(group.name)
                        } else {
                            DisclosureGroup {
                                ForEach(group.documents) { document in
                                    noteRow(document, rowKey: document.id)
                                        .tag(document.id)
                                }
                            } label: {
                                folderRow(group.name)
                            }
                        }
                    }
                } header: {
                    Text("知识库")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .dropDestination(for: String.self) { paths, _ in
                            moveDocuments(at: paths, toFolder: "")
                        }
                }
            case .favorites:
                Section("收藏") {
                    ForEach(store.favoriteDocuments) { document in
                        noteRow(document, rowKey: document.id)
                            .tag(document.id)
                    }
                }
            case .recent:
                Section("最近修改") {
                    ForEach(store.recentDocuments) { document in
                        noteRow(document, rowKey: document.id)
                            .tag(document.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if libraryFilter == .favorites && store.favoriteDocuments.isEmpty {
                ContentUnavailableView(
                    "还没有收藏",
                    systemImage: "star",
                    description: Text("右键文稿即可添加收藏。")
                )
            }
        }
    }

    private var searchResults: some View {
        List(store.searchResults) { hit in
            Button {
                store.select(hit.document)
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if store.searchResults.isEmpty {
                ContentUnavailableView.search(text: store.searchQuery)
            }
        }
    }

    private var statusBar: some View {
        HStack {
            if store.isIndexing {
                ProgressView().controlSize(.small)
                Text("正在更新索引")
            } else {
                Text("\(store.documents.count) 篇文稿")
            }
            Spacer()
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
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private func noteRow(
        _ document: NoteDocument,
        rowKey: String
    ) -> some View {
        Label {
            if renameTargetRowKey == rowKey {
                TextField("文稿名称", text: $renameText)
                    .textFieldStyle(.plain)
                    .focused($renameFocus, equals: .document(rowKey))
                    .onSubmit { commitDocumentRename(document) }
                    .onExitCommand { cancelRename() }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(document.title).lineLimit(1)
                    if !document.folder.isEmpty {
                        Text(document.folder)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        } icon: {
            Image(systemName: document.kindIcon)
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button(store.favorites.contains(document.relativePath) ? "取消收藏" : "收藏") {
                store.toggleFavorite(document)
            }
            Button("重命名…") {
                beginRenaming(document, rowKey: rowKey)
            }
            Button("在 Finder 中显示") { store.revealInFinder(document) }
            Divider()
            Button("移到废纸篓", role: .destructive) { deleteTarget = document }
        }
        .draggable(document.relativePath)
    }

    @ViewBuilder
    private func folderRow(_ folder: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            if folderRenameTarget == folder {
                TextField("文件夹名称", text: $renameText)
                    .textFieldStyle(.plain)
                    .focused($renameFocus, equals: .folder(folder))
                    .onSubmit { commitFolderRename(folder) }
                    .onExitCommand { cancelRename() }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(folderDisplayName(folder))
                        .lineLimit(1)
                    if !folderParentPath(folder).isEmpty {
                        Text(folderParentPath(folder))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("重命名…") { beginRenamingFolder(folder) }
            Divider()
            Button("移到废纸篓", role: .destructive) {
                deleteFolderTarget = folder
            }
        }
        .dropDestination(for: String.self) { paths, _ in
            moveDocuments(at: paths, toFolder: folder)
        }
    }

    private func beginRenaming(_ document: NoteDocument, rowKey: String) {
        folderRenameTarget = nil
        renameTargetRowKey = rowKey
        renameText = document.title
        DispatchQueue.main.async {
            renameFocus = .document(rowKey)
        }
    }

    private func beginRenamingFolder(_ folder: String) {
        renameTargetRowKey = nil
        folderRenameTarget = folder
        renameText = folderDisplayName(folder)
        DispatchQueue.main.async {
            renameFocus = .folder(folder)
        }
    }

    private func commitDocumentRename(_ document: NoteDocument) {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        cancelRename()
        store.rename(document, to: name)
    }

    private func commitFolderRename(_ folder: String) {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        cancelRename()
        store.renameFolder(folder, to: name)
    }

    private func cancelRename() {
        renameFocus = nil
        renameTargetRowKey = nil
        folderRenameTarget = nil
        renameText = ""
    }

    private func moveDocuments(at paths: [String], toFolder folder: String) -> Bool {
        let documents = paths.compactMap { path in
            store.documents.first(where: { $0.relativePath == path })
        }
        guard !documents.isEmpty else { return false }
        for document in documents where document.folder != folder {
            store.move(document, toFolder: folder)
        }
        return true
    }

    private func folderDisplayName(_ folder: String) -> String {
        (folder as NSString).lastPathComponent
    }

    private func folderParentPath(_ folder: String) -> String {
        let parent = (folder as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }

    private func documents(in folder: String) -> [NoteDocument] {
        store.documents.filter {
            $0.folder == folder || $0.folder.hasPrefix(folder + "/")
        }
    }
}
