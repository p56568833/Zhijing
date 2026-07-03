import SwiftUI

struct ContentView: View {
    @Bindable var store: AppStore
    @AppStorage("sidebarPaneWidth") private var sidebarPaneWidth = 260.0
    @AppStorage("assistantPaneWidth") private var assistantPaneWidth = 350.0

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
                            dragDirection: 1
                        )
                    }

                    EditorView(store: store)
                        .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)

                    if store.isAssistantVisible {
                        ResizablePaneDivider(
                            paneWidth: $assistantPaneWidth,
                            range: 300...480,
                            dragDirection: -1
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
