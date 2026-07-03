import SwiftUI

struct EditorView: View {
    @Bindable var store: AppStore
    @State private var showVersions = false

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            Divider()
            Group {
                if let document = store.selectedDocument {
                    if store.isPreviewMode {
                        MarkdownReadingView(text: store.editorText)
                    } else {
                        MarkdownSourceEditor(
                            text: $store.editorText,
                            documentID: document.id
                        ) {
                            store.editorDidChange()
                        }
                            .accessibilityLabel("\(document.title) 编辑器")
                    }
                } else {
                    ContentUnavailableView(
                        "选择一篇文稿",
                        systemImage: "doc.text",
                        description: Text("从左侧知识库中选择，或新建一篇 Markdown 文稿。")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .popover(isPresented: $showVersions, arrowEdge: .bottom) {
            VersionHistoryView(store: store)
        }
    }

    private var editorHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.selectedDocument?.title ?? "未选择文稿")
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if store.saveState == .saving {
                        ProgressView().controlSize(.mini)
                    }
                    Text(store.saveState.label)
                    if let folder = store.selectedDocument?.folder, !folder.isEmpty {
                        Text("·")
                        Text(folder)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if store.selectedDocument != nil {
                Button {
                    showVersions.toggle()
                } label: {
                    Label("版本", systemImage: "clock.arrow.circlepath")
                }
                .help("版本历史")
                Picker("编辑模式", selection: $store.isPreviewMode) {
                    Text("编辑").tag(false)
                    Text("阅读").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }
}

private struct VersionHistoryView: View {
    let store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("版本历史").font(.headline)
                Spacer()
                Button("创建快照") { store.createManualSnapshot() }
            }
            Divider()
            if store.revisions.isEmpty {
                Text("还没有历史版本")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.revisions) { revision in
                            HStack {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.secondary)
                                Text(revision.createdAt.formatted(date: .abbreviated, time: .standard))
                                Spacer()
                                Button("恢复") { store.restore(revision) }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 360, height: 260)
    }
}
