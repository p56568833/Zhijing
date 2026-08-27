import Foundation
import Testing
@testable import Zhijing

private func mutation(
    source: String,
    location: Int,
    length: Int,
    style: InlineMarkdownFormatting.WrapStyle
) -> InlineWrapMutation? {
    InlineMarkdownFormatting.mutation(
        in: source,
        selection: NSRange(location: location, length: length),
        style: style
    )
}

@Test func wrapsSelectionWithBoldMarkers() throws {
    let source = "说一段话"
    // "一段" 位于第 1–3 个字符。
    let result = try #require(mutation(
        source: source,
        location: 1,
        length: 2,
        style: .bold
    ))

    #expect(result.replacementText == "**一段**")
    #expect(result.range.location == 1)
    #expect(result.selectionRange == NSRange(location: 3, length: 2))
}

@Test func unwrapsWhenMarkersAreAdjacent() throws {
    let source = "说**段话**"
    // 选中 "段话"（标记内部）。
    let result = try #require(mutation(
        source: source,
        location: 3,
        length: 2,
        style: .bold
    ))

    #expect(result.replacementText == "段话")
    #expect(result.selectionRange == NSRange(location: 1, length: 2))
}

@Test func italicUsesSingleAsterisk() throws {
    let result = try #require(mutation(
        source: "文字",
        location: 0,
        length: 2,
        style: .italic
    ))

    #expect(result.replacementText == "*文字*")
}

@Test func strikethroughUsesDoubleTilde() throws {
    let result = try #require(mutation(
        source: "文字",
        location: 0,
        length: 2,
        style: .strikethrough
    ))

    #expect(result.replacementText == "~~文字~~")
}

@Test func rejectsMultilineAndBlankSelections() {
    #expect(mutation(
        source: "第一行\n第二行",
        location: 0,
        length: 6,
        style: .bold
    ) == nil)
    #expect(mutation(
        source: "文字",
        location: 1,
        length: 0,
        style: .bold
    ) == nil)
}

@Test func colorMarkKindsRoundTripThroughSyntax() {
    let source = "前缀 [红色文字]{.red} 中间 [绿色文字]{.green} 结尾"
    let spans = InlineTextMarkMarkdown.spans(in: source)

    #expect(spans.map(\.kind) == [.red, .green])
    #expect(InlineTextMarkMarkdown.encoded("样本", as: .blue) == "[样本]{.blue}")

    let stripped = InlineTextMarkMarkdown.removingSyntax(from: source)
    #expect(stripped == "前缀 红色文字 中间 绿色文字 结尾")
}

@Test func applyingColorMarkMutationProducesColorSyntax() throws {
    let source = "普通文字"
    let mutation = try #require(InlineTextMarkMarkdown.mutation(
        in: source,
        selection: NSRange(location: 0, length: 4),
        applying: .red
    ))

    #expect(mutation.replacementText == "[普通文字]{.red}")
    #expect(mutation.selectionRange == NSRange(location: 1, length: 4))
}
