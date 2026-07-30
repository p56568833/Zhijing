import Foundation
import Testing
@testable import Zhijing

@MainActor
@Test func aiSettingsControllerOwnsProviderConfigurationAndSecretWrites() throws {
    let suiteName = "AISettingsControllerTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("https://example.com/v1", forKey: "endpoint")
    defaults.set("custom-model", forKey: "model")
    var savedKey = ""
    let controller = AISettingsController(
        defaults: defaults,
        loadAPIKey: { "" },
        saveAPIKey: { savedKey = $0 }
    )

    #expect(controller.provider == .custom)
    controller.apiKey = "test-key"
    #expect(savedKey == "test-key")
    let customConfiguration = try controller.configuration()
    #expect(
        customConfiguration.endpoint.absoluteString
            == "https://example.com/v1/chat/completions"
    )

    controller.selectProvider(.deepSeek)
    #expect(controller.endpoint == "https://api.deepseek.com")
    #expect(controller.model == AIProviderPreset.deepSeek.defaultModel)
    #expect(defaults.string(forKey: "provider") == "deepSeek")
}

@MainActor
@Test func documentFindControllerKeepsTransitionsConsistent() {
    let controller = DocumentFindController()
    controller.options = DocumentFindOptions(
        query: "needle",
        matchCase: true,
        wholeWord: true
    )
    controller.updateResult(DocumentFindResult(
        matchCount: 3,
        selectedIndex: 1
    ))

    controller.navigate(.next)
    #expect(controller.isVisible)
    #expect(controller.navigationRequest?.direction == .next)
    #expect(controller.result.matchCount == 3)

    controller.hide()
    #expect(!controller.isVisible)
    #expect(controller.options.query.isEmpty)
    #expect(controller.options.matchCase)
    #expect(controller.options.wholeWord)
    #expect(controller.result == DocumentFindResult())
    #expect(controller.navigationRequest == nil)
}

@Test func annotationResolutionCacheReusesACompleteDisplaySnapshot() {
    let text = "甲。需要批注的段落。乙。"
    let selected = "需要批注的段落"
    let range = (text as NSString).range(of: selected)
    let selection = EditorTextSelection(
        documentID: "note",
        range: range,
        text: selected
    )
    let anchor = try! #require(
        TextAnnotationAnchorResolver.makeAnchor(
            selection: selection,
            in: text
        )
    )
    let annotation = TextAnnotation(anchor: anchor, text: "批注")
    var cache = AnnotationResolutionCache()

    let first = cache.resolve(
        documentKey: "note",
        annotations: [annotation],
        text: text
    )
    let second = cache.resolve(
        documentKey: "note",
        annotations: [annotation],
        text: text
    )

    #expect(first == second)
    #expect(first.resolved.map(\.id) == [annotation.id])
    #expect(first.displayItems.map(\.range) == [range])
    #expect(cache.cacheMissCount == 1)

    _ = cache.resolve(
        documentKey: "note",
        annotations: [annotation],
        text: text + "丙。"
    )
    #expect(cache.cacheMissCount == 2)
}

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
