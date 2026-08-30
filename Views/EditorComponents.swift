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

/// 标签拖拽（Chrome 式）：拖的是标签本体，1:1 跟手；被拖标签在布局流里
/// 原位隐身充当「洞」（视图身份不变，手势不会因视图替换被打断），洞跨过
/// 相邻兄弟的可见中心时兄弟才让位。松手时洞的位置就是最终位置，本体原地
/// 显形，没有二次归位动画。
struct DocumentTabBar: View {
    let store: AppStore
    @State private var drag: TabDragState?
    @State private var tabFrames: [String: CGRect] = [:]

    /// 拖拽期状态。兄弟标签的相对顺序和基准中心全程固定，
    /// 拖拽中唯一变化的量是洞的位置（insertionIndex）。
    private struct TabDragState {
        let document: NoteDocument
        let originalIndex: Int
        let width: CGFloat
        let baseMinX: CGFloat              // 拖起时相对首标签左缘的偏移
        let contentWidth: CGFloat          // 拖起时整行内容宽度
        let siblings: [NoteDocument]
        let siblingBaseCenters: [CGFloat]  // 兄弟标签拖起时的中心
        var translation: CGFloat = 0
        var insertionIndex: Int
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(displayOrder) { document in
                    let isDragged = drag?.document.id == document.id
                    DocumentTabItem(
                        title: document.title,
                        isSelected: store.selectedDocument?.id == document.id,
                        select: { store.select(document) },
                        close: { store.closeDocumentTab(document) }
                    )
                    .background(frameReader(for: document))
                    // 被拖标签原位隐身充当洞；真实外观由跟手浮层负责。
                    // 动画只挂在标签自身上，不要包住浮层——否则每次换位
                    // 浮层的 offset 都会被拽着做动画，跟不上手。
                    .opacity(isDragged ? 0 : 1)
                    .animation(.snappy(duration: 0.22), value: orderSignature)
                }
            }
            .overlay(alignment: .leading) { floatingTab }
            // 标签本体是 Button，普通 .gesture 会输给按钮的点击追踪，
            // 从标签文字上按下的拖动拿不到 move 事件（浮层不动）。
            // 高优先级手势：未移动 5pt 前点击照常，越过后拖动立即接管。
            .highPriorityGesture(reorderGesture())
            .coordinateSpace(name: "tabBarSpace")
            .padding(.horizontal, 8)
        }
        .frame(height: 40)
        .onPreferenceChange(TabFrameKey.self) { tabFrames = $0 }
    }

    /// 拖拽中：兄弟按原相对顺序排布，被拖标签插在 insertionIndex 处
    /// （隐身即洞）；平时：按 store 里的打开顺序排布。
    private var displayOrder: [NoteDocument] {
        guard let drag else { return store.openDocuments }
        var slots = drag.siblings
        slots.insert(drag.document, at: min(drag.insertionIndex, slots.count))
        return slots
    }

    private var orderSignature: String {
        displayOrder.map(\.id).joined(separator: "\u{2028}")
    }

    /// 跟手的标签本体：位置 = 拖起位置 + 夹在行内的指针位移。
    /// 拖动中按选中态渲染（实底背景），无论原本是否选中都清晰可见。
    @ViewBuilder
    private var floatingTab: some View {
        if let drag {
            DocumentTabItem(
                title: drag.document.title,
                isSelected: true,
                select: {},
                close: {}
            )
            .frame(width: drag.width)
            .scaleEffect(1.05)
            .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
            .offset(x: drag.baseMinX + drag.translation)
            .allowsHitTesting(false)
            .transition(.identity)
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

    private func reorderGesture() -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("tabBarSpace"))
            .onChanged { value in
                if drag == nil {
                    beginDrag(at: value.startLocation)
                    guard drag != nil else { return }
                }
                updateDrag(with: value.translation.width)
            }
            .onEnded { value in
                finishDrag(finalTranslation: value.translation.width)
            }
    }

    private func beginDrag(at startLocation: CGPoint) {
        let tabs = store.openDocuments
        guard !tabs.isEmpty,
              tabs.allSatisfy({ tabFrames[$0.id] != nil }),
              let document = tab(at: startLocation),
              let frame = tabFrames[document.id],
              let firstFrame = tabFrames[tabs[0].id],
              let lastFrame = tabFrames[tabs[tabs.count - 1].id]
        else { return }
        let index = tabs.firstIndex(where: { $0.id == document.id }) ?? 0
        drag = TabDragState(
            document: document,
            originalIndex: index,
            width: frame.width,
            baseMinX: frame.minX - firstFrame.minX,
            contentWidth: lastFrame.maxX - firstFrame.minX,
            siblings: tabs.filter { $0.id != document.id },
            siblingBaseCenters: tabs.compactMap {
                $0.id == document.id ? nil : tabFrames[$0.id]?.midX
            },
            insertionIndex: index
        )
        NSCursor.closedHand.push()
    }

    private func updateDrag(with translation: CGFloat) {
        guard var drag else { return }
        let maxX = max(0, drag.contentWidth - drag.width)
        let x = min(max(drag.baseMinX + translation, 0), maxX)
        drag.translation = x - drag.baseMinX
        drag.insertionIndex = insertionIndex(forCenter: x + drag.width / 2, of: drag)
        self.drag = drag
    }

    /// 让位阈值取相邻兄弟的「当前可见中心」：洞右侧的兄弟被推右了
    /// (标签宽 + 间距)，向右拖要越过推移后的中心；洞左侧的兄弟在
    /// 原位，向左拖越过原中心即可。阈值随换位切换，天然带滞后。
    private func insertionIndex(forCenter center: CGFloat, of drag: TabDragState) -> Int {
        let shift = drag.width + 4
        var index = drag.insertionIndex
        while index < drag.siblingBaseCenters.count,
              center > drag.siblingBaseCenters[index] + shift {
            index += 1
        }
        while index > 0,
              center < drag.siblingBaseCenters[index - 1] {
            index -= 1
        }
        return index
    }

    private func finishDrag(finalTranslation: CGFloat?) {
        guard var settledDrag = drag else { return }
        NSCursor.pop()
        // 中途的 move 事件可能被合并或丢弃，松手时用最终位移
        // 兜底重算洞位，避免「拖到位了却弹回原位」。
        if let finalTranslation {
            let maxX = max(0, settledDrag.contentWidth - settledDrag.width)
            let x = min(
                max(settledDrag.baseMinX + finalTranslation, 0),
                maxX
            )
            settledDrag.translation = x - settledDrag.baseMinX
            settledDrag.insertionIndex = insertionIndex(
                forCenter: x + settledDrag.width / 2,
                of: settledDrag
            )
        }
        drag = nil
        guard settledDrag.insertionIndex != settledDrag.originalIndex else {
            return
        }
        store.moveDocumentTab(settledDrag.document, toIndex: settledDrag.insertionIndex)
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
