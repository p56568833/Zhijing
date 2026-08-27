import SwiftUI

struct EditorView: View {
    @Bindable var store: AppStore
    @State private var showVersions = false
    @AppStorage("comparisonPaneWidth") private var savedComparisonPaneWidth = 420.0
    @State private var comparisonPaneWidth = PaneWidthPreference.load(
        key: "comparisonPaneWidth",
        default: 420,
        range: 340...700
    )
    @AppStorage("annotationPaneWidth") private var savedAnnotationPaneWidth = 300.0
    @State private var annotationPaneWidth = PaneWidthPreference.load(
        key: "annotationPaneWidth",
        default: 300,
        range: 270...380
    )
    @State private var isLegacyAnnotationPaneVisible = false

    var body: some View {
        VStack(spacing: 0) {
            editorChrome
            if isFormatBarVisible {
                Divider()
                FormatBar(store: store)
            }
            if store.isDocumentFindVisible,
               store.selectedDocument != nil,
               store.editProposal == nil {
                Divider()
                DocumentFindBar(store: store)
            }
            Divider()
            if let proposal = store.editProposal {
                DiffReviewView(store: store, proposal: proposal)
                    .id(proposal.id)
            } else if store.isComparisonVisible {
                HStack(spacing: 0) {
                    annotatedPrimaryEditor
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
                annotatedPrimaryEditor
                    .clipped()
            }
            Divider()
            DocumentMetricsBar(store: store)
        }
        .background(ZhijingTheme.paper)
        .sheet(isPresented: $showVersions) {
            VersionHistoryView(store: store)
        }
        .onChange(of: store.selectedDocument?.id) {
            isLegacyAnnotationPaneVisible = false
        }
        .onChange(of: store.isPreviewMode) {
            store.editorSelectionDidChange(nil)
        }
    }

    private var isFormatBarVisible: Bool {
        store.selectedDocument != nil
            && !store.isPreviewMode
            && store.editProposal == nil
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
                .disabled(store.editProposal != nil)
                DocumentActionsMenu(
                    isComparisonVisible: store.isComparisonVisible,
                    legacyAnnotationCount: store.currentAnnotations.count,
                    isLegacyAnnotationPaneVisible: legacyAnnotationPanePresented,
                    isDisabled: store.editProposal != nil,
                    showVersions: { showVersions = true },
                    toggleComparison: store.toggleComparison,
                    addAnnotation: store.requestAnnotationComposer,
                    toggleLegacyAnnotations: {
                        isLegacyAnnotationPaneVisible.toggle()
                    },
                    exportPDF: { store.exportCurrentDocument(as: .pdf) },
                    exportWord: { store.exportCurrentDocument(as: .word) }
                )
                Picker("编辑模式", selection: $store.isPreviewMode) {
                    Text("编辑").tag(false)
                    Text("阅读").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(store.editProposal != nil)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(ZhijingTheme.chrome)
    }

    @ViewBuilder
    private var annotatedPrimaryEditor: some View {
        HStack(spacing: 0) {
            primaryEditor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let document = store.selectedDocument,
               legacyAnnotationPanePresented {
                ResizablePaneDivider(
                    paneWidth: $annotationPaneWidth,
                    range: 270...380,
                    dragDirection: -1,
                    onDragEnded: { width in
                        savedAnnotationPaneWidth = width
                    }
                )
                AnnotationRailView(
                    documentTitle: document.title,
                    items: store.currentAnnotationDisplayItems,
                    composerRequest: nil,
                    onCreate: { _, _ in },
                    onCancelComposer: {},
                    onReveal: store.revealAnnotation,
                    onUpdate: store.updateAnnotation,
                    onToggleResolved: store.toggleAnnotationResolution,
                    onRelink: store.relinkAnnotation,
                    onDelete: store.deleteAnnotation,
                    onClose: { isLegacyAnnotationPaneVisible = false }
                )
                .frame(width: annotationPaneWidth)
            }
        }
    }

    private var legacyAnnotationPanePresented: Bool {
        isLegacyAnnotationPaneVisible && !store.currentAnnotationDisplayItems.isEmpty
    }

    @ViewBuilder
    private var primaryEditor: some View {
        if let document = store.selectedDocument {
            if store.isPreviewMode {
                MarkdownReadingView(
                    text: store.editorText,
                    baseURL: document.url.deletingLastPathComponent(),
                    onSelectionChange: store.readingSelectionDidChange,
                    onToggleTaskLine: { line in
                        store.toggleTaskCheckbox(atLine: line)
                    }
                )
            } else {
                MarkdownSourceEditor(
                    text: store.editorText,
                    documentID: document.id,
                    contentRevision: store.editorContentRevision,
                    navigationRequest: store.editorNavigationRequest,
                    findOptions: store.documentFindOptions,
                    findNavigationRequest: store.documentFindNavigationRequest,
                    annotations: store.currentResolvedAnnotations,
                    inlineAnnotationRequestID: store.inlineAnnotationRequestID,
                    formatRequest: store.formatRequest,
                    onChange: store.editorDidChange,
                    onSelectionChange: store.editorSelectionDidChange,
                    onFindResultChange: store.updateDocumentFindResult,
                    onFindCommand: store.handleDocumentFindCommand
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

private struct FormatBar: View {
    let store: AppStore

    var body: some View {
        HStack(spacing: 2) {
            formatButton("bold", "加粗（⌘B）") {
                store.applyInlineFormat(.bold)
            }
            formatButton("italic", "斜体（⌘I）") {
                store.applyInlineFormat(.italic)
            }
            formatButton("strikethrough", "删除线（⇧⌘X）") {
                store.applyInlineFormat(.strikethrough)
            }
            barDivider
            formatButton("underline", "下划线标记") {
                store.applyInlineFormat(.textMark(.underline))
            }
            formatButton("highlighter", "荧光标记（⇧⌘H）") {
                store.applyInlineFormat(.textMark(.highlight))
            }
            colorMenu
            barDivider
            formatButton("eraser", "清除标记") {
                store.applyInlineFormat(.clearTextMark)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(ZhijingTheme.chrome)
    }

    private var barDivider: some View {
        Divider()
            .frame(height: 14)
            .padding(.horizontal, 5)
    }

    private var colorMenu: some View {
        Menu {
            Button("红色文字") { store.applyInlineFormat(.textMark(.red)) }
            Button("橙色文字") { store.applyInlineFormat(.textMark(.orange)) }
            Button("绿色文字") { store.applyInlineFormat(.textMark(.green)) }
            Button("蓝色文字") { store.applyInlineFormat(.textMark(.blue)) }
        } label: {
            Image(systemName: "paintpalette")
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("彩色文字")
    }

    private func formatButton(
        _ systemImage: String,
        _ helpText: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
    }
}
