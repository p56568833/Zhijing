import SwiftUI

struct ContentView: View {
    @Bindable var store: AppStore
    @AppStorage("sidebarPaneWidth") private var savedSidebarPaneWidth = 260.0
    @AppStorage("assistantPaneWidth") private var savedAssistantPaneWidth = 350.0
    @State private var sidebarPaneWidth =
        UserDefaults.standard.object(forKey: "sidebarPaneWidth") as? Double ?? 260.0
    @State private var assistantPaneWidth =
        UserDefaults.standard.object(forKey: "assistantPaneWidth") as? Double ?? 350.0

    var body: some View {
        Group {
            if store.libraryURL == nil {
                WelcomeView(store: store)
            } else {
                HStack(spacing: 0) {
                    if store.isSidebarVisible {
                        SidebarView(store: store)
                            .frame(width: sidebarPaneWidth)
                        ResizablePaneDivider(
                            paneWidth: $sidebarPaneWidth,
                            range: 210...360,
                            dragDirection: 1,
                            onDragEnded: { width in
                                savedSidebarPaneWidth = width
                            }
                        )
                    }

                    EditorView(store: store)
                        .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)

                    if store.isAssistantVisible {
                        ResizablePaneDivider(
                            paneWidth: $assistantPaneWidth,
                            range: 300...480,
                            dragDirection: -1,
                            onDragEnded: { width in
                                savedAssistantPaneWidth = width
                            }
                        )
                        AssistantView(store: store)
                            .frame(width: assistantPaneWidth)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            store.toggleSidebar()
                        } label: {
                            Label("切换侧栏", systemImage: "sidebar.left")
                        }
                    }
                    ToolbarItem {
                        Button {
                            store.createNote()
                        } label: {
                            Label("新建文稿", systemImage: "square.and.pencil")
                        }
                    }
                    ToolbarItem {
                        Button {
                            store.toggleAssistant()
                        } label: {
                            Label("AI 助手", systemImage: "sparkles")
                        }
                    }
                    ToolbarItem {
                        SettingsLink {
                            Label("API 设置", systemImage: "gearshape")
                        }
                        .help("API 与模型设置（⌘,）")
                    }
                }
            }
        }
        .sheet(item: $store.editProposal) { proposal in
            DiffReviewView(store: store, proposal: proposal)
        }
        .sheet(item: $store.selectionEditRequest) { request in
            SelectionEditPromptView(store: store, request: request)
        }
        .sheet(item: $store.externalConflict) { conflict in
            ExternalConflictView(store: store, conflict: conflict)
        }
    }
}

private struct ExternalConflictView: View {
    let store: AppStore
    let conflict: ExternalFileConflict

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        conflict.fileWasRemoved
                            ? "文稿已在外部被移动或删除"
                            : "文稿在其他应用中发生了修改"
                    )
                    .font(.title2.weight(.semibold))
                    Text("知境暂停了自动保存，避免覆盖任何一方的内容。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)

            Divider()

            if let diskText = conflict.diskText {
                TextComparisonView(
                    originalTitle: "知境中的版本",
                    original: conflict.localText,
                    replacementTitle: "磁盘上的版本",
                    replacement: diskText
                )
            } else {
                ContentUnavailableView(
                    "磁盘上已找不到这篇文稿",
                    systemImage: "doc.badge.ellipsis",
                    description: Text("可以在原位置重新创建，或放弃知境中尚未保存的修改。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack {
                Text(conflict.document.relativePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if conflict.fileWasRemoved {
                    Button("放弃本地修改", role: .destructive) {
                        store.discardLocalVersionAfterExternalRemoval()
                    }
                    Button("在原位置重新创建") {
                        store.keepLocalVersionAfterConflict()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("使用磁盘版本") {
                        store.loadExternalVersionAfterConflict()
                    }
                    Button("保留知境版本") {
                        store.keepLocalVersionAfterConflict()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(14)
        }
        .frame(minWidth: 900, minHeight: 620)
        .interactiveDismissDisabled()
    }
}

private struct SelectionEditPromptView: View {
    let store: AppStore
    let request: SelectionEditRequest
    @State private var instruction = ""
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("修改所选内容", systemImage: "wand.and.stars")
                .font(.headline)
            Text(request.selection.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            TextField("例如：更简洁，但保留这个例子", text: $instruction, axis: .vertical)
                .lineLimit(2...5)
                .focused($isFocused)
                .onSubmit(submit)
            HStack {
                Text("AI 会读取必要上下文，但只返回修改片段")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                Button("生成修改", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear { isFocused = true }
    }

    private func submit() {
        let value = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        store.selectionEditRequest = nil
        store.proposeSelectionEdit(
            instruction: value,
            selection: request.selection
        )
        dismiss()
    }
}

private struct WelcomeView: View {
    let store: AppStore

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "books.vertical")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 7) {
                Text("知境")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("在自己的 Markdown 知识库里，边写、边搜索、边与 AI 共创。")
                    .foregroundStyle(.secondary)
            }
            Button("打开知识库文件夹…") {
                store.chooseLibrary()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            SettingsLink {
                Label("API 与模型设置", systemImage: "key.horizontal")
            }
            Text("文稿始终保留在你的 Mac 上")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
