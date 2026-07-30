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

    var body: some View {
        VStack(spacing: 0) {
            editorChrome
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
                .disabled(store.editProposal != nil)
                Button {
                    showVersions.toggle()
                } label: {
                    Label("版本", systemImage: "clock.arrow.circlepath")
                        .labelStyle(.iconOnly)
                }
                .help("版本历史")
                .buttonStyle(.plain)
                .disabled(store.editProposal != nil)
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
                .disabled(store.editProposal != nil)
                Button {
                    if store.currentAnnotations.isEmpty,
                       store.annotationComposerRequest == nil {
                        store.requestAnnotationComposer()
                    } else {
                        store.toggleAnnotationRail()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isAnnotationPanePresented
                              ? "text.bubble.fill"
                              : "text.bubble")
                        if !store.currentAnnotations.isEmpty {
                            Text("\(store.currentAnnotations.count)")
                                .font(.caption2.monospacedDigit())
                        }
                    }
                }
                .accessibilityLabel("批注")
                .help(annotationButtonHelp)
                .buttonStyle(.plain)
                .foregroundStyle(isAnnotationPanePresented ? Color.orange : Color.primary)
                .disabled(store.editProposal != nil)
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
                .disabled(store.editProposal != nil)
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
        .background(.bar)
    }

    @ViewBuilder
    private var annotatedPrimaryEditor: some View {
        HStack(spacing: 0) {
            primaryEditor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let document = store.selectedDocument,
               isAnnotationPanePresented {
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
                    composerRequest: store.annotationComposerRequest,
                    onCreate: { text, selection in
                        store.addAnnotation(text: text, selection: selection)
                    },
                    onCancelComposer: store.cancelAnnotationComposer,
                    onReveal: store.revealAnnotation,
                    onUpdate: store.updateAnnotation,
                    onToggleResolved: store.toggleAnnotationResolution,
                    onRelink: store.relinkAnnotation,
                    onDelete: store.deleteAnnotation,
                    onClose: store.toggleAnnotationRail
                )
                .frame(width: annotationPaneWidth)
            }
        }
    }

    private var isAnnotationPanePresented: Bool {
        store.isAnnotationRailVisible
            && (!store.currentAnnotationDisplayItems.isEmpty
                || store.annotationComposerRequest != nil)
    }

    private var annotationButtonHelp: String {
        if isAnnotationPanePresented { return "隐藏批注" }
        if store.currentAnnotations.isEmpty { return "选中文字后添加批注（⇧⌘M）" }
        return "显示批注"
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
                    annotations: store.currentResolvedAnnotations,
                    onChange: store.editorDidChange,
                    onSelectionChange: store.editorSelectionDidChange,
                    onFindResultChange: store.updateDocumentFindResult,
                    onFindCommand: store.handleDocumentFindCommand,
                    onAIEditAction: store.handleSelectionEditAction,
                    onRequestAnnotation: store.beginAnnotation
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
