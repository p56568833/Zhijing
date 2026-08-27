import SwiftUI

/// 标签页帧测量用的偏好键，拖拽换位时用它定位落点。
private struct TabFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct DocumentTabBar: View {
    let store: AppStore
    @State private var draggingTabID: String?
    @State private var dragAnchorMidX: CGFloat?
    @State private var tabFrames: [String: CGRect] = [:]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(store.openDocuments) { document in
                    DocumentTabItem(
                        title: document.title,
                        isSelected: store.selectedDocument?.id == document.id,
                        select: { store.select(document) },
                        close: { store.closeDocumentTab(document) }
                    )
                    .opacity(draggingTabID == document.id ? 0.65 : 1)
                    .background(frameReader(for: document))
                    .gesture(reorderGesture(for: document))
                }
            }
            .coordinateSpace(name: "tabBarSpace")
            .padding(.horizontal, 8)
        }
        .frame(height: 40)
        .onPreferenceChange(TabFrameKey.self) { tabFrames = $0 }
    }

    private func frameReader(for document: NoteDocument) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: TabFrameKey.self,
                value: [document.id: geo.frame(in: .named("tabBarSpace"))]
            )
        }
    }

    /// 手势驱动的拖拽换位：按下时对基准位置拍一次快照，
    /// 拖过相邻标签的中线才移动一格——基准不随换位刷新，
    /// 杜绝"换位后偏移量叠加"导致的连环乱飞。
    private func reorderGesture(for document: NoteDocument) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard draggingTabID == nil || draggingTabID == document.id else { return }
                if draggingTabID == nil {
                    guard let frame = tabFrames[document.id] else { return }
                    draggingTabID = document.id
                    dragAnchorMidX = frame.midX
                }
                guard let anchorMidX = dragAnchorMidX else { return }
                let pointerMidX = anchorMidX + value.translation.width

                let order = store.openDocuments
                guard let index = order.firstIndex(where: { $0.id == document.id })
                else { return }

                var destination: Int?
                if index + 1 < order.count,
                   let nextFrame = tabFrames[order[index + 1].id],
                   pointerMidX > nextFrame.midX {
                    destination = index + 1
                } else if index > 0,
                          let previousFrame = tabFrames[order[index - 1].id],
                          pointerMidX < previousFrame.midX {
                    destination = index - 1
                }
                guard let destination else { return }
                withAnimation(.easeInOut(duration: 0.14)) {
                    store.moveDocumentTab(order[index], toIndex: destination)
                }
            }
            .onEnded { _ in
                draggingTabID = nil
                dragAnchorMidX = nil
            }
    }
}

private struct DocumentTabItem: View {
    let title: String
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Button(action: select) {
                Text(title)
                    .font(.callout.weight(isSelected ? .medium : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: 180)
            }
            .buttonStyle(.plain)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭标签页")
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: 28)
        .background(tabBackground, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(isSelected ? ZhijingTheme.accent.opacity(0.18) : .clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
    }

    private var tabBackground: Color {
        if isSelected { return ZhijingTheme.paper }
        if isHovering { return ZhijingTheme.paper.opacity(0.58) }
        return .clear
    }
}

struct DocumentActionsMenu: View {
    let isComparisonVisible: Bool
    let legacyAnnotationCount: Int
    let isLegacyAnnotationPaneVisible: Bool
    let isDisabled: Bool
    let showVersions: () -> Void
    let toggleComparison: () -> Void
    let addAnnotation: () -> Void
    let toggleLegacyAnnotations: () -> Void
    let exportPDF: () -> Void
    let exportWord: () -> Void

    var body: some View {
        Menu {
            Button("添加批注…", systemImage: "text.bubble", action: addAnnotation)
            Button("版本历史", systemImage: "clock.arrow.circlepath", action: showVersions)
            Button(
                isComparisonVisible ? "关闭分屏对照" : "打开分屏对照",
                systemImage: "rectangle.split.2x1",
                action: toggleComparison
            )
            if legacyAnnotationCount > 0 {
                Button(
                    isLegacyAnnotationPaneVisible ? "隐藏旧版批注" : "显示旧版批注（\(legacyAnnotationCount)）",
                    systemImage: isLegacyAnnotationPaneVisible ? "archivebox.fill" : "archivebox",
                    action: toggleLegacyAnnotations
                )
            }
            Divider()
            Menu("导出", systemImage: "square.and.arrow.up") {
                Button("导出 PDF…", action: exportPDF)
                Button("导出 Word…", action: exportWord)
            }
        } label: {
            Label("文稿工具", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(isDisabled)
        .help("版本、对照、批注与导出")
        .accessibilityLabel("文稿工具")
    }
}

struct DocumentFindBar: View {
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
        .background(ZhijingTheme.chrome)
        .onAppear { isFocused = true }
    }

    private var resultText: String {
        store.documentFindOptions.trimmedQuery.isEmpty
            ? ""
            : store.documentFindResult.displayText
    }
}

struct ReferenceDocumentView: View {
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

struct DocumentMetricsBar: View {
    let store: AppStore

    var body: some View {
        HStack(spacing: 14) {
            if store.selectedDocument != nil {
                if store.saveState == .saving {
                    ProgressView().controlSize(.mini)
                }
                Text(store.saveState.label)
                if let location = store.selectedDocumentLocationLabel {
                    Text("·")
                    Text(location)
                        .lineLimit(1)
                }
            }
            Spacer()
            metricsSummary
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(ZhijingTheme.chrome)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private var metricsSummary: some View {
        HStack(spacing: 6) {
            if let selection = store.selectionMetrics {
                Label(
                    "已选 \(selection.count.formatted()) 字",
                    systemImage: "selection.pin.in.out"
                )
                Text("·")
                Text("口播\(selection.speakingDurationLabel)")
                Text("·")
                Text("全文 \(store.documentWordCount.formatted()) 字")
            } else {
                Label(
                    "\(store.documentWordCount.formatted()) 字",
                    systemImage: "textformat"
                )
                Text("·")
                Text("口播\(store.documentSpeakingDurationLabel)")
            }
        }
        .lineLimit(1)
    }

    private var accessibilitySummary: String {
        if let selection = store.selectionMetrics {
            return "\(store.saveState.label)，已选 \(selection.count.formatted()) 字，口播\(selection.speakingDurationLabel)，全文 \(store.documentWordCount.formatted()) 字"
        }
        return "\(store.saveState.label)，\(store.documentWordCount.formatted()) 字，口播\(store.documentSpeakingDurationLabel)"
    }
}
