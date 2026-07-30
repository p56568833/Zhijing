import Foundation
import Testing
@testable import Zhijing

@Test func aiContextBuilderKeepsSelectionAndRelevantLongDocumentSections() {
    let lines = (0..<1_800).map { index in
        index == 900 ? "目标主题出现在这里" : "普通内容 \(index)"
    }
    let text = lines.joined(separator: "\n")
    let selectionText = "目标主题出现在这里"
    let selectionRange = (text as NSString).range(of: selectionText)
    let document = NoteDocument(
        url: URL(filePath: "/tmp/context.md"),
        relativePath: "context.md",
        modifiedAt: .distantPast,
        size: text.utf8.count
    )
    let selection = EditorTextSelection(
        documentID: document.id,
        range: selectionRange,
        text: selectionText
    )

    let context = AIContextBuilder.answerContext(
        question: "目标主题",
        document: document,
        text: text,
        selection: selection,
        annotations: []
    )

    #expect(context.contains("[当前选区]"))
    #expect(context.contains(selectionText))
    #expect(context.contains("[相关片段"))
    #expect(context.contains("[结尾]"))
    #expect(context.utf16.count < text.utf16.count)
}

@Test func aiContextBuilderCalculatesSelectionLineRanges() {
    let text = "第一行\n第二行\n第三行\n第四行"
    let range = (text as NSString).range(of: "第二行\n第三行")

    #expect(AIContextBuilder.lineRange(for: range, in: text) == 1..<3)
    #expect(AIContextBuilder.contains(range, range: NSRange(
        location: range.location,
        length: 3
    )))
}
