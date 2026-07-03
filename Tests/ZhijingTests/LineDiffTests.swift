import Testing
import Foundation
import AppKit
@testable import Zhijing

@Test func lineDiffFindsInsertionsAndRemovals() {
    let diff = LineDiff(
        original: "第一行\n旧内容\n最后一行",
        replacement: "第一行\n新内容\n最后一行"
    )
    #expect(diff.removedOffsets == [1])
    #expect(diff.insertedOffsets == [1])
}

@Test func retrievalScopeTitlesRemainStable() {
    #expect(RetrievalScope.library.rawValue == "整个知识库")
    #expect(RetrievalScope.currentFolder.rawValue == "当前文件夹")
}

@Test func providerPresetsMatchModelsAndEndpoints() {
    #expect(AIProviderPreset.openAI.endpoint == "https://api.openai.com/v1")
    #expect(AIProviderPreset.openAI.models.contains { $0.id == "gpt-5.4-mini" })
    #expect(AIProviderPreset.deepSeek.endpoint == "https://api.deepseek.com")
    #expect(AIProviderPreset.deepSeek.models.contains { $0.id == "deepseek-v4-flash" })
    #expect(AIProviderPreset.custom.endpoint == nil)
}

@Test func baseURLsResolveToChatCompletionRequests() {
    #expect(
        AIEndpointResolver.chatCompletionsURL(from: "https://api.deepseek.com")?.absoluteString
            == "https://api.deepseek.com/chat/completions"
    )
    #expect(
        AIEndpointResolver.chatCompletionsURL(from: "https://api.openai.com/v1")?.absoluteString
            == "https://api.openai.com/v1/chat/completions"
    )
    #expect(
        AIEndpointResolver.chatCompletionsURL(
            from: "https://example.com/v1/chat/completions"
        )?.absoluteString == "https://example.com/v1/chat/completions"
    )
}

@Test func connectionTestRejectsMissingKeyBeforeNetworking() async {
    let configuration = AIConfiguration(
        apiKey: "",
        endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
        model: "gpt-5.4-mini",
        provider: .openAI
    )

    do {
        try await AIService().testConnection(configuration: configuration)
        Issue.record("缺少 API Key 时不应通过连接测试")
    } catch {
        #expect(error.localizedDescription == "请先填写 API Key。")
    }
}

@Test func legacyChatMessagesDecodeWithoutUsageFields() throws {
    let json = """
    {
      "id": "8C2A97BB-5E39-4E4A-A928-D6843C31C842",
      "role": "assistant",
      "text": "旧回复",
      "createdAt": 0,
      "sources": [],
      "isGeneralKnowledge": false
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let message = try decoder.decode(ChatMessage.self, from: Data(json.utf8))
    #expect(message.usage == nil)
    #expect(message.cost == nil)
}

@Test func chineseSearchAvoidsSingleCharacterNoise() throws {
    let root = URL(filePath: NSTemporaryDirectory())
        .appending(path: "ZhijingSearch-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "这里介绍全文搜索。".write(
        to: root.appending(path: "无关.md"),
        atomically: true,
        encoding: .utf8
    )
    try "知识库检索应该按需工作。".write(
        to: root.appending(path: "相关.md"),
        atomically: true,
        encoding: .utf8
    )
    let service = KnowledgeBaseService()
    let documents = try service.scan(root: root, excludedFolders: [])
    let hits = service.search(query: "检索", documents: documents)
    #expect(Set(hits.map(\.document.title)) == ["相关"])
}

@Test func scanIncludesLongMarkdownExtension() throws {
    let root = URL(filePath: NSTemporaryDirectory())
        .appending(path: "ZhijingMarkdown-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "可见内容".write(
        to: root.appending(path: "长扩展名.markdown"),
        atomically: true,
        encoding: .utf8
    )

    let documents = try KnowledgeBaseService().scan(root: root, excludedFolders: [])
    #expect(documents.map(\.title) == ["长扩展名"])
}

@Test func staleEditProposalCannotOverwriteNewTyping() {
    let proposal = EditProposal(
        documentPath: "文章.md",
        original: "生成建议时的正文",
        replacement: "AI 修改后的正文",
        instruction: "润色"
    )

    #expect(proposal.canApply(to: "文章.md", currentText: "生成建议时的正文"))
    #expect(!proposal.canApply(to: "文章.md", currentText: "用户后来输入的新正文"))
    #expect(!proposal.canApply(to: "另一篇.md", currentText: "生成建议时的正文"))
}

@MainActor
@Test func syntaxHighlightingPreservesCaretAffinity() {
    let textView = NSTextView()
    textView.string = "一段刚好可能换行的文字"
    let range = NSRange(location: 5, length: 0)
    textView.setSelectedRange(range, affinity: .upstream, stillSelecting: false)

    MarkdownSourceEditor.Coordinator.preserveEditingState(of: textView) {
        textView.textStorage?.addAttribute(
            .foregroundColor,
            value: NSColor.labelColor,
            range: NSRange(location: 0, length: textView.string.utf16.count)
        )
    }

    #expect(textView.selectedRange() == range)
    #expect(textView.selectionAffinity == .upstream)
}

@MainActor
@Test func markdownLinksDoNotInstallNativeTextViewLinkAttributes() {
    let source = "[OpenAI](https://openai.com)"
    let attributed = MarkdownSyntaxHighlighter.attributedString(source)

    #expect(attributed.attribute(.link, at: 1, effectiveRange: nil) == nil)
    #expect(
        attributed.attribute(.underlineStyle, at: 1, effectiveRange: nil) as? Int
            == NSUnderlineStyle.single.rawValue
    )
}

@Test func publicHTTPAIEndpointIsRejectedBeforeNetworking() async {
    let configuration = AIConfiguration(
        apiKey: "test-key",
        endpoint: URL(string: "http://example.com/v1/chat/completions")!,
        model: "test-model",
        provider: .custom
    )

    do {
        try await AIService().testConnection(configuration: configuration)
        Issue.record("公网 HTTP 地址不应接收 API Key")
    } catch {
        #expect(error.localizedDescription.contains("必须使用 HTTPS"))
    }
}

@Test func readingModeRemovesMarkdownSourceMarkers() {
    let source = """
    # **标题**

    > 一段引用

    - 列表项目

    [链接文字](https://example.com)
    """
    let blocks = MarkdownReadingParser.parse(source)
    let visibleText = blocks
        .map { String(MarkdownInlineRenderer.render($0.content).characters) }
        .joined(separator: "\n")

    #expect(visibleText.contains("标题"))
    #expect(visibleText.contains("一段引用"))
    #expect(visibleText.contains("列表项目"))
    #expect(visibleText.contains("链接文字"))
    #expect(!visibleText.contains("#"))
    #expect(!visibleText.contains("**"))
    #expect(!visibleText.contains(">"))
    #expect(!visibleText.contains("https://"))
}
