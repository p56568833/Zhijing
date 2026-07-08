import SwiftUI

struct EditorView: View {
    @Bindable var store: AppStore
    @State private var showVersions = false
    @AppStorage("comparisonPaneWidth") private var savedComparisonPaneWidth = 420.0
    @State private var comparisonPaneWidth =
        UserDefaults.standard.object(forKey: "comparisonPaneWidth") as? Double ?? 420.0

    var body: some View {
        VStack(spacing: 0) {
            editorChrome
            if store.isDocumentFindVisible, store.selectedDocument != nil {
                Divider()
                DocumentFindBar(store: store)
            }
            Divider()
            if store.isComparisonVisible {
                HStack(spacing: 0) {
                    primaryEditor
                        .frame(
                            minWidth: 360,
                            maxWidth: .infinity,
                            maxHeight: .infinity
                        )
                        .clipped()
                    ResizablePaneDivider(
                        paneWidth: $comparisonPaneWidth,
                        range: 340...700,
                        dragDirection: -1,
                        onDragEnded: { width in
                            savedComparisonPaneWidth = width
                        }
                    )
                    ReferenceDocumentView(store: store)
                        .frame(width: comparisonPaneWidth)
                }
                .clipped()
            } else {
                primaryEditor
                    .clipped()
            }
            Divider()
            DocumentMetricsBar(store: store)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(isPresented: $showVersions) {
            VersionHistoryView(store: store)
        }
    }

    private var editorChrome: some View {
        HStack(spacing: 8) {
            DocumentTabBar(store: store)
                .frame(minWidth: 120, maxWidth: .infinity)
            if store.selectedDocument != nil {
                Divider()
                    .frame(height: 20)
                Button {
                    store.showDocumentFind()
                } label: {
                    Label("查找", systemImage: "magnifyingglass")
                        .labelStyle(.iconOnly)
                }
                .help("查找当前文稿（⌘F）")
                .buttonStyle(.plain)
                Button {
                    showVersions.toggle()
                } label: {
                    Label("版本", systemImage: "clock.arrow.circlepath")
                        .labelStyle(.iconOnly)
                }
                .help("版本历史")
                .buttonStyle(.plain)
                Button {
                    store.toggleComparison()
                } label: {
                    Label(
                        store.isComparisonVisible ? "关闭对照" : "分屏对照",
                        systemImage: "rectangle.split.2x1"
                    )
                    .labelStyle(.iconOnly)
                }
                .help("左右分屏对照另一篇文稿")
                .buttonStyle(.plain)
                Menu {
                    Button("导出 PDF…") {
                        store.exportCurrentDocument(as: .pdf)
                    }
                    Button("导出 Word…") {
                        store.exportCurrentDocument(as: .word)
                    }
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Picker("编辑模式", selection: $store.isPreviewMode) {
                    Text("编辑").tag(false)
                    Text("阅读").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(.bar)
    }

    @ViewBuilder
    private var primaryEditor: some View {
        if let document = store.selectedDocument {
            if store.isPreviewMode {
                MarkdownReadingView(text: store.editorText)
            } else {
                MarkdownSourceEditor(
                    text: store.editorText,
                    documentID: document.id,
                    contentRevision: store.editorContentRevision,
                    navigationRequest: store.editorNavigationRequest,
                    findOptions: store.documentFindOptions,
                    findNavigationRequest: store.documentFindNavigationRequest,
                    onChange: store.editorDidChange,
                    onSelectionChange: store.editorSelectionDidChange,
                    onFindResultChange: store.updateDocumentFindResult,
                    onFindCommand: store.handleDocumentFindCommand,
                    onAIEditAction: store.handleSelectionEditAction
                )
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
}

private struct DocumentTabBar: View {
    let store: AppStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(store.openDocuments) { document in
                    HStack(spacing: 5) {
                        Button {
                            store.select(document)
                        } label: {
                            Text(document.title)
                                .lineLimit(1)
                                .frame(maxWidth: 180)
                        }
                        .buttonStyle(.plain)

                        Button {
                            store.closeDocumentTab(document)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.plain)
                        .help("关闭标签页")
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 5)
                    .frame(height: 28)
                    .background(
                        store.selectedDocument?.id == document.id
                            ? Color.accentColor.opacity(0.16)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 40)
    }
}

private struct DocumentFindBar: View {
    @Bindable var store: AppStore
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                "在当前文稿中查找",
                text: Binding(
                    get: { store.documentFindOptions.query },
                    set: { store.documentFindOptions.query = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .frame(minWidth: 180, maxWidth: 360)
            .onSubmit { store.findNext() }

            Text(resultText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)

            Button {
                store.findPrevious()
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .help("上一个（⇧⌘G）")
            .disabled(store.documentFindResult.matchCount == 0)

            Button {
                store.findNext()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .help("下一个（⌘G）")
            .disabled(store.documentFindResult.matchCount == 0)

            Toggle(
                "Aa",
                isOn: Binding(
                    get: { store.documentFindOptions.matchCase },
                    set: { store.documentFindOptions.matchCase = $0 }
                )
            )
            .toggleStyle(.button)
            .help("区分大小写")

            Toggle(
                "整词",
                isOn: Binding(
                    get: { store.documentFindOptions.wholeWord },
                    set: { store.documentFindOptions.wholeWord = $0 }
                )
            )
            .toggleStyle(.button)
            .help("整词匹配")

            Spacer()

            Button {
                store.hideDocumentFind()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("关闭查找")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.bar)
        .onAppear { isFocused = true }
    }

    private var resultText: String {
        store.documentFindOptions.trimmedQuery.isEmpty
            ? ""
            : store.documentFindResult.displayText
    }
}

private struct ReferenceDocumentView: View {
    let store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("对照文稿", systemImage: "doc.on.doc")
                    .font(.headline)
                Spacer()
                Picker(
                    "对照文稿",
                    selection: Binding(
                        get: { store.comparisonDocumentPath },
                        set: { store.setComparisonDocument($0) }
                    )
                ) {
                    ForEach(store.comparisonCandidates) { document in
                        Text(document.title)
                            .tag(Optional(document.relativePath))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 240)
                Button {
                    store.toggleComparison()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("关闭分屏对照")
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            Divider()

            if store.comparisonDocument != nil {
                MarkdownReadingView(text: store.comparisonText)
            } else {
                ContentUnavailableView(
                    "选择一篇对照文稿",
                    systemImage: "rectangle.split.2x1"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DocumentMetricsBar: View {
    let store: AppStore

    var body: some View {
        HStack(spacing: 14) {
            if store.selectedDocument != nil {
                if store.saveState == .saving {
                    ProgressView().controlSize(.mini)
                }
                Text(store.saveState.label)
                if let folder = store.selectedDocument?.folder, !folder.isEmpty {
                    Text("·")
                    Text(folder)
                        .lineLimit(1)
                }
            }
            Spacer()
            Label("\(store.documentWordCount.formatted()) 字", systemImage: "textformat")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(store.saveState.label)，\(store.documentWordCount.formatted()) 字"
        )
    }
}

private struct VersionHistoryView: View {
    let store: AppStore
    @State private var selectedRevisionID: Revision.ID?
    @State private var selectedRevisionText = ""
    @State private var loadedRevisionID: Revision.ID?
    @State private var isLoadingRevision = false
    @State private var snapshotName = ""
    @State private var mode = VersionDisplayMode.preview
    @State private var restoreTarget: Revision?
    @Environment(\.dismiss) private var dismiss

    private enum VersionDisplayMode: String, CaseIterable, Identifiable {
        case preview = "预览"
        case compare = "与当前比较"

        var id: Self { self }
    }

    private var selectedRevision: Revision? {
        guard let selectedRevisionID else { return store.revisions.first }
        return store.revisions.first { $0.id == selectedRevisionID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("版本历史")
                        .font(.title2.weight(.semibold))
                    Text(store.selectedDocument?.title ?? "")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                TextField("快照名称，例如：完成初稿", text: $snapshotName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit(createNamedSnapshot)
                Button("保存快照", action: createNamedSnapshot)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        snapshotName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
            .padding(18)
            Divider()

            HSplitView {
                Group {
                    if store.revisions.isEmpty {
                        ContentUnavailableView(
                            "还没有历史版本",
                            systemImage: "clock.arrow.circlepath",
                            description: Text("为重要节点命名并保存快照。")
                        )
                    } else {
                        List(store.revisions, selection: $selectedRevisionID) { revision in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(revision.displayName)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                Text(
                                    revision.createdAt.formatted(
                                        date: .abbreviated,
                                        time: .standard
                                    )
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .tag(revision.id)
                        }
                        .listStyle(.sidebar)
                    }
                }
                .frame(minWidth: 230, idealWidth: 260, maxWidth: 320)

                VStack(spacing: 0) {
                    if let revision = selectedRevision {
                        HStack {
                            Picker("查看方式", selection: $mode) {
                                ForEach(VersionDisplayMode.allCases) { value in
                                    Text(value.rawValue).tag(value)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            Spacer()
                            Button("恢复这个版本") {
                                restoreTarget = revision
                            }
                        }
                        .padding(12)
                        Divider()

                        if isLoadingRevision || loadedRevisionID != revision.id {
                            ProgressView("正在载入版本…")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            switch mode {
                            case .preview:
                                MarkdownReadingView(text: selectedRevisionText)
                            case .compare:
                                TextComparisonView(
                                    originalTitle: revision.displayName,
                                    original: selectedRevisionText,
                                    replacementTitle: "当前文稿",
                                    replacement: store.editorText
                                )
                            }
                        }
                    } else {
                        ContentUnavailableView(
                            "选择一个版本",
                            systemImage: "doc.text.magnifyingglass"
                        )
                    }
                }
            }

            Divider()
            HStack {
                Text("恢复版本前，知境会先保存当前内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding(14)
        }
        .frame(minWidth: 960, minHeight: 640)
        .onAppear {
            selectedRevisionID = store.revisions.first?.id
        }
        .task(id: selectedRevisionID) {
            await loadSelectedRevisionText()
        }
        .confirmationDialog(
            "恢复“\(restoreTarget?.displayName ?? "")”？",
            isPresented: Binding(
                get: { restoreTarget != nil },
                set: { if !$0 { restoreTarget = nil } }
            )
        ) {
            Button("恢复版本") {
                if let restoreTarget {
                    store.restore(restoreTarget)
                }
                self.restoreTarget = nil
            }
            Button("取消", role: .cancel) { restoreTarget = nil }
        } message: {
            Text("当前文稿会先自动保存为一个快照。")
        }
    }

    private func createNamedSnapshot() {
        let name = snapshotName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.createManualSnapshot(name: name)
        snapshotName = ""
        selectedRevisionID = store.revisions.first?.id
    }

    @MainActor
    private func loadSelectedRevisionText() async {
        guard let revision = selectedRevision else {
            selectedRevisionText = ""
            loadedRevisionID = nil
            isLoadingRevision = false
            return
        }

        if loadedRevisionID == revision.id {
            return
        }

        isLoadingRevision = true
        let id = revision.id
        let url = revision.url
        let text = await Task.detached(priority: .userInitiated) {
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }.value
        guard selectedRevision?.id == id else { return }
        selectedRevisionText = text
        loadedRevisionID = id
        isLoadingRevision = false
    }
}
