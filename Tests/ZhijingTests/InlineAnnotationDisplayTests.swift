import AppKit
import Foundation
import Testing
@testable import Zhijing

@Test func hiddenExcerptRangeCoversExcerptAndSeparatorLines() throws {
    let source = """
    正文一段。

    > 批注
    > 原文 · 「正文一段。」
    >
    > 这是批注内容。
    """
    let ranges = InlineAnnotationMarkdown.hiddenExcerptRanges(in: source)
    #expect(ranges.count == 1)
    let range = try #require(ranges.first)
    let hidden = (source as NSString).substring(with: range)
    // 覆盖原文行和空分隔行，含分隔行末尾的换行。
    #expect(hidden == "> 原文 · 「正文一段。」\n>\n")
    // 折叠后标题行和内容行直接相连。
    let visible = (source as NSString).replacingCharacters(
        in: range,
        with: ""
    )
    #expect(visible.contains("> 批注\n> 这是批注内容。"))
}

@Test func blocksWithoutCanonicalExcerptStayVisible() {
    // 没有原文行或分隔行不是 ">" 时不动手。
    let withoutExcerpt = "> 批注\n> 手写的内容"
    #expect(InlineAnnotationMarkdown.hiddenExcerptRanges(in: withoutExcerpt).isEmpty)

    let withoutSeparator = "> 批注\n> 原文 · 「节选」\n> 内容紧跟着"
    let ranges = InlineAnnotationMarkdown.hiddenExcerptRanges(in: withoutSeparator)
    #expect(ranges.count == 1)
    let hidden = (withoutSeparator as NSString).substring(with: ranges[0])
    #expect(hidden == "> 原文 · 「节选」\n")
}

@Test func headingContentRangesListAnnotationBlocksInDocumentOrder() {
    let source = """
    开头

    > 批注
    > 原文 · 「一」
    >
    > 甲

    中间正文

    > 批注
    > 原文 · 「二」
    >
    > 乙
    """
    let ranges = InlineAnnotationMarkdown.annotationHeadingContentRanges(in: source)
    #expect(ranges.count == 2)
    let source_ns = source as NSString
    #expect(source_ns.substring(with: ranges[0]) == "批注")
    #expect(source_ns.substring(with: ranges[1]) == "批注")
    #expect(ranges[0].location < ranges[1].location)
}

@Test func circledNumbersCoverCommonRangesThenFallBack() {
    #expect(InlineAnnotationMarkdown.circledNumber(1) == "①")
    #expect(InlineAnnotationMarkdown.circledNumber(20) == "⑳")
    #expect(InlineAnnotationMarkdown.circledNumber(30) == "㉚")
    #expect(InlineAnnotationMarkdown.circledNumber(31) == "(31)")
    #expect(InlineAnnotationMarkdown.circledNumber(0) == "(0)")
}

@Test func readingExcerptShortensLongQuotesAndKeepsShortOnes() {
    let long = "原文 · 「公司刚起步的时候，朴振英听到一盘 demo，觉得里面的编曲很有灵气，一打听才知道出处不凡。」"
    let shortened = InlineAnnotationMarkdown.shortenedExcerpt(from: long)
    #expect(shortened.hasSuffix("……」"))
    #expect(shortened.count < long.count)
    #expect(shortened.hasPrefix("原文 · 「"))

    let short = "原文 · 「一句短话」"
    #expect(InlineAnnotationMarkdown.shortenedExcerpt(from: short) == short)

    let plain = "随手写的一句话"
    #expect(InlineAnnotationMarkdown.shortenedExcerpt(from: plain) == plain)
}

@Test func annotationBlockRangeCoversBlockAndLeadingBlankLine() throws {
    let source = "第一段。\n\n> 批注\n> 原文 · 「第一段。」\n>\n> 111\n\n第三段。\n"
    let nsSource = source as NSString

    // 光标在标题行、内容行、折叠的原文行内，都能定位整块（含块前空行）。
    for probe in ["批注", "原文", "> ", "111"] {
        let location = nsSource.range(of: probe).location
        let blockRange = try #require(
            InlineAnnotationMarkdown.annotationBlockRange(at: location, in: source)
        )
        let removed = nsSource.substring(with: blockRange)
        #expect(removed == "\n> 批注\n> 原文 · 「第一段。」\n>\n> 111\n")
    }

    // 光标在普通段落里没有块。
    #expect(InlineAnnotationMarkdown.annotationBlockRange(
        at: 1,
        in: source
    ) == nil)
    // 文档没有批注块时返回 nil。
    #expect(InlineAnnotationMarkdown.annotationBlockRange(at: 0, in: "只有正文") == nil)
}

@Test func freshAnnotationResolvesAgainstTextWithInsertedBlock() throws {
    let paragraph = "打个比方，一个美国网友偶然刷到巴西粉丝剪的 BTS 搞笑日常切片，觉得挺逗；视频里是英国粉丝熬夜翻译的字幕。"
    var text = "前面的话。\n\(paragraph)\n后面的话。\n"
    let originalRange = (text as NSString).range(of: paragraph)
    let selection = EditorTextSelection(
        documentID: "/tmp/note.md",
        range: originalRange,
        text: paragraph
    )
    let anchor = try #require(
        TextAnnotationAnchorResolver.makeAnchor(selection: selection, in: text)
    )
    let annotation = TextAnnotation(anchor: anchor, text: "111")

    // 模拟编辑器真实写入：选区行后插入批注块。
    let insertion = try #require(InlineAnnotationMarkdown.insertion(
        in: text,
        selection: selection.range,
        annotation: "111"
    ))
    text = (text as NSString).replacingCharacters(
        in: insertion.range,
        with: insertion.replacementText
    )

    let resolved = try #require(
        TextAnnotationAnchorResolver.resolve(annotation, in: text)
    )
    #expect(resolved.range == originalRange)

    let headings = InlineAnnotationMarkdown.annotationHeadingContentRanges(in: text)
    #expect(headings.count == 1)
    // 配对条件：锚点结束位置在批注块标题之前。
    #expect(NSMaxRange(resolved.range) <= headings[0].location)
}

@MainActor
@Test func updateAnnotationsProducesWaveVisualsForAnchoredBlock() throws {
    let paragraph = "第二段要批注的话。"
    let source = "第一段。\n\(paragraph)\n第三段。\n\n> 批注\n> 原文 · 「\(paragraph)」\n>\n> 111\n"
    let range = (source as NSString).range(of: paragraph)
    let selection = EditorTextSelection(
        documentID: "/tmp/note.md",
        range: range,
        text: paragraph
    )
    let anchor = try #require(
        TextAnnotationAnchorResolver.makeAnchor(selection: selection, in: source)
    )
    let annotation = TextAnnotation(anchor: anchor, text: "111")
    let resolved = try #require(
        TextAnnotationAnchorResolver.resolve(annotation, in: source)
    )

    let scrollView = NSScrollView(
        frame: NSRect(x: 0, y: 0, width: 500, height: 180)
    )
    let textView = MarkdownEditorTextView(frame: scrollView.contentView.bounds)
    textView.isRichText = false
    textView.isHorizontallyResizable = false
    textView.textContainer?.containerSize = NSSize(
        width: scrollView.contentSize.width,
        height: CGFloat.greatestFiniteMagnitude
    )
    textView.textContainer?.widthTracksTextView = true
    MarkdownSourceEditor.Coordinator.applyPlainTextAppearance(to: textView)
    textView.enableTextMarkSyntaxFolding()
    textView.string = source
    scrollView.documentView = textView
    textView.layoutManager?.ensureLayout(
        for: try #require(textView.textContainer)
    )

    textView.updateAnnotations([resolved])

    #expect(textView.annotationVisuals.count == 1)
    #expect(textView.annotationVisuals.first?.range == range)
    #expect(textView.annotationVisuals.first?.number == 1)
}
