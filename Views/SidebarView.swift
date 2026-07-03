import SwiftUI

struct SidebarView: View {
    @Bindable var store: AppStore
    @State private var renameTarget: NoteDocument?
    @State private var renameText = ""
    @State private var deleteTarget: NoteDocument?

    var body: some View {
        VStack(spacing: 0) {
            searchBar
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
        .sheet(item: $renameTarget) { target in
            RenameSheet(name: $renameText) {
                store.rename(target, to: renameText)
                renameTarget = nil
            } onCancel: {
                renameTarget = nil
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

    private var libraryList: some View {
        List(selection: Binding(
            get: { store.selectedDocument?.id },
            set: { id in
                if let document = store.documents.first(where: { $0.id == id }) {
                    store.select(document)
                }
            }
        )) {
            if !store.favoriteDocuments.isEmpty {
                Section("收藏") {
                    ForEach(store.favoriteDocuments) { document in
                        noteRow(document).tag(document.id)
                    }
                }
            }
            if !store.recentDocuments.isEmpty {
                Section("最近打开") {
                    ForEach(store.recentDocuments.prefix(4)) { document in
                        noteRow(document).tag(document.id)
                    }
                }
            }
            Section("知识库") {
                ForEach(groupedFolders, id: \.name) { group in
                    if group.name.isEmpty {
                        ForEach(group.documents) { document in
                            noteRow(document).tag(document.id)
                        }
                    } else {
                        DisclosureGroup {
                            ForEach(group.documents) { document in
                                noteRow(document).tag(document.id)
                            }
                        } label: {
                            Label(group.name, systemImage: "folder")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
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

    private func noteRow(_ document: NoteDocument) -> some View {
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
        .contextMenu {
            Button(store.favorites.contains(document.relativePath) ? "取消收藏" : "收藏") {
                store.toggleFavorite(document)
            }
            Button("重命名…") {
                renameText = document.title
                renameTarget = document
            }
            Button("在 Finder 中显示") { store.revealInFinder(document) }
            Divider()
            Button("移到废纸篓", role: .destructive) { deleteTarget = document }
        }
    }

    private var groupedFolders: [(name: String, documents: [NoteDocument])] {
        let groups = Dictionary(grouping: store.documents, by: \.folder)
        return groups.map { ($0.key, $0.value) }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

private struct RenameSheet: View {
    @Binding var name: String
    let onRename: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重命名文稿").font(.headline)
            TextField("文件名", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onRename)
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("重命名", action: onRename)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 380)
    }
}
