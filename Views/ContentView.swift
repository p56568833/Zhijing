import SwiftUI

struct ContentView: View {
    @Bindable var store: AppStore
    @AppStorage("sidebarPaneWidth") private var savedSidebarPaneWidth = 260.0
    @State private var sidebarPaneWidth = PaneWidthPreference.load(
        key: "sidebarPaneWidth",
        default: 260,
        range: 210...360
    )

    var body: some View {
        Group {
            if store.libraryURL == nil {
                WelcomeView(store: store)
            } else {
                HStack(spacing: 0) {
                    if store.isSidebarVisible {
                        SidebarView(store: store)
                            .frame(width: sidebarPaneWidth)
                            .frame(maxHeight: .infinity, alignment: .top)
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
                }
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button {
                            store.toggleSidebar()
                        } label: {
                            Label("切换侧栏", systemImage: "sidebar.left")
                        }
                        Button {
                            store.createNote()
                        } label: {
                            Label("新建文稿", systemImage: "plus")
                        }
                        .help("新建 Markdown 文稿（⌘N）")
                    }
                }
                .overlay(alignment: .bottom) {
                    if let notice = store.followedMoveNotice {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(notice.displayText)
                                .lineLimit(1)
                            Spacer(minLength: 12)
                            Button {
                                store.dismissFollowedMoveNotice()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                        }
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: 520)
                        .background(
                            .regularMaterial,
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.25), value: store.followedMoveNotice)
            }
        }
        .tint(ZhijingTheme.accent)
        .background(ZhijingTheme.canvas)
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

private struct WelcomeView: View {
    let store: AppStore

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "books.vertical")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(ZhijingTheme.accent)
            VStack(spacing: 7) {
                Text("知境")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("在自己的 Markdown 知识库里，专注写作、搜索与整理。")
                    .foregroundStyle(.secondary)
            }
            Button("打开知识库文件夹…") {
                store.chooseLibrary()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            SettingsLink {
                Label("偏好设置", systemImage: "slider.horizontal.3")
            }
            Text("文稿始终保留在你的 Mac 上")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ZhijingTheme.canvas)
    }
}
