import AppKit
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
    @State private var dragGhostOffsetX: CGFloat = 0
    @State private var dragGhostBaseOffsetX: CGFloat = 0
    @State private var dragStartMidX: CGFloat?
    @State private var dragSlotMidXs: [CGFloat] = []
    @State private var dragActiveOrder: [NoteDocument]?
    @State private var dragMovedAny = false
    @State private var tabFrames: [String: CGRect] = [:]

    var body: some View {
        let tabs = dragActiveOrder ?? store.openDocuments
        let orderSignature = tabs.map(\.id).joined(separator: "\u{2028}")
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tabs) { document in
                    let isDragged = draggingTabID == document.id
                    DocumentTabItem(
                        title: document.title,
                        isSelected: store.selectedDocument?.id == document.id,
                        select: { store.select(document) },
                        close: { store.closeDocumentTab(document) }
                    )
                    .background(frameReader(for: document))
                    // 被拖标签的原位隐身，充当占位空隙；真实外观由浮层负责
                    .opacity(isDragged ? 0 : 1)
                    .animation(.snappy(duration: 0.24), value: orderSignature)
                }
            }
            .overlay(alignment: .leading) {
                dragGhost(tabs: tabs)
            }
            .gesture(reorderGesture())
            .coordinateSpace(name: "tabBarSpace")
            .padding(.horizontal, 8)
        }
        .frame(height: 40)
        .onPreferenceChange(TabFrameKey.self) { tabFrames = $0 }
    }

    /// 跟随指针的浮层标签：位置 = 原槽位 + 纯指针位移。
    /// 它不参与布局，换位时其余标签怎么动都影响不到它。
    @ViewBuilder
    private func dragGhost(tabs: [NoteDocument]) -> some View {
        if let id = draggingTabID,
           let document = tabs.first(where: { $0.id == id }) {
            DocumentTabItem(
                title: document.title,
                isSelected: store.selectedDocument?.id == document.id,
                select: {},
                close: {}
            )
            .scaleEffect(1.05)
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .offset(x: dragGhostBaseOffsetX + dragGhostOffsetX)
            .allowsHitTesting(false)
            .animation(.snappy(duration: 0.16), value: draggingTabID == nil)
        }
    }

    private func frameReader(for document: NoteDocument) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: TabFrameKey.self,
                value: [document.id: geo.frame(in: .named("tabBarSpace"))]
            )
        }
    }

    private func tab(at point: CGPoint) -> NoteDocument? {
        store.openDocuments.first { document in
            guard let frame = tabFrames[document.id] else { return false }
            return point.x >= frame.minX && point.x <= frame.maxX
        }
    }

    /// 标签栏级拖拽手势：起点落在哪个标签就拖哪个。
    /// 手势挂在标签栏容器上——容器本身在拖拽期间永远不动，
    /// translation 始终是纯指针位移，从根上杜绝位移污染造成的乱飞。
    private func reorderGesture() -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("tabBarSpace"))
            .onChanged { value in
                if dragActiveOrder == nil {
                    let tabs = store.openDocuments
                    guard !tabs.isEmpty,
                          tabs.allSatisfy({ tabFrames[$0.id] != nil }),
                          let document = tab(at: value.startLocation),
                          let frame = tabFrames[document.id],
                          let firstFrame = tabFrames[tabs[0].id]
                    else { return }
                    draggingTabID = document.id
                    dragStartMidX = frame.midX
                    dragSlotMidXs = tabs.map { tabFrames[$0.id]!.midX }
                    dragGhostBaseOffsetX = frame.minX - firstFrame.minX
                    dragGhostOffsetX = 0
                    dragActiveOrder = tabs
                    dragMovedAny = false
                    NSCursor.closedHand.push()
                }
                guard let startMidX = dragStartMidX,
                      let visible = dragActiveOrder,
                      let draggedID = draggingTabID,
                      let index = visible.firstIndex(where: { $0.id == draggedID }),
                      !dragSlotMidXs.isEmpty,
                      index < dragSlotMidXs.count
                else { return }

                // 跟手，但夹在首尾槽位中线之间：标签拖不出标签栏。
                let visualMidX = min(
                    max(startMidX + value.translation.width, dragSlotMidXs.first!),
                    dragSlotMidXs.last!
                )
                dragGhostOffsetX = visualMidX - startMidX

                var target = index
                while target + 1 < dragSlotMidXs.count,
                      visualMidX > (dragSlotMidXs[target] + dragSlotMidXs[target + 1]) / 2 {
                    target += 1
                }
                while target > 0,
                      visualMidX < (dragSlotMidXs[target - 1] + dragSlotMidXs[target]) / 2 {
                    target -= 1
                }
                guard target != index else { return }
                dragActiveOrder = DocumentOrdering.moved(
                    visible, fromIndex: index, toIndex: target
                )
                dragMovedAny = true
            }
            .onEnded { _ in
                finishDrag()
            }
    }

    /// 松手：最终位置一次性提交回 store，浮层从指针处弹回空隙槽位；
    /// 真实标签保持隐身，等浮层落稳后再显形，位置逐像素相同。
    private func finishDrag() {
        guard let activeOrder = dragActiveOrder,
              let draggedID = draggingTabID,
              let startMidX = dragStartMidX,
              let index = activeOrder.firstIndex(where: { $0.id == draggedID }),
              !dragSlotMidXs.isEmpty,
              index < dragSlotMidXs.count
        else { return }
        NSCursor.pop()
        let moved = dragMovedAny
        dragMovedAny = false
        dragActiveOrder = nil
        dragStartMidX = nil
        if moved {
            store.moveDocumentTab(activeOrder[index], toIndex: index)
        }
        let landingOffset = dragSlotMidXs[index] - startMidX
        dragSlotMidXs = []
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            dragGhostOffsetX = landingOffset
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.4))
            if draggingTabID == draggedID, dragActiveOrder == nil {
                draggingTabID = nil
            }
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
