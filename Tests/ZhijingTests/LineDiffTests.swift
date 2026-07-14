import Testing
import Foundation
import AppKit
import PDFKit
@testable import Zhijing

@Test func lineDiffFindsInsertionsAndRemovals() {
    let diff = LineDiff(
        original: "第一行\n旧内容\n最后一行",
        replacement: "第一行\n新内容\n最后一行"
    )
    #expect(diff.removedOffsets == [1])
    #expect(diff.insertedOffsets == [1])
}

@Test func lineDiffAppliesOnlySelectedChangeHunks() {
    let diff = LineDiff(
        original: "开头\n旧段一\n中间\n旧段二\n结尾",
        replacement: "开头\n新段一\n中间\n新段二\n结尾"
    )

    #expect(diff.hunks.count == 2)
    #expect(
        diff.applying(acceptedHunkIDs: [diff.hunks[0].id])
            == "开头\n新段一\n中间\n旧段二\n结尾"
    )
    #expect(
        diff.applying(acceptedHunkIDs: [diff.hunks[1].id])
            == "开头\n旧段一\n中间\n新段二\n结尾"
    )
}

@Test func lineDiffHandlesPureInsertionsAndDeletionsAsSelectableHunks() {
    let insertion = LineDiff(
        original: "开头\n结尾",
        replacement: "开头\n新增\n结尾"
    )
    #expect(insertion.hunks.count == 1)
    #expect(
        insertion.applying(acceptedHunkIDs: [0])
            == "开头\n新增\n结尾"
    )
    #expect(
        insertion.applying(acceptedHunkIDs: [])
            == "开头\n结尾"
    )

    let deletion = LineDiff(
        original: "开头\n删除\n结尾",
        replacement: "开头\n结尾"
    )
    #expect(deletion.hunks.count == 1)
    #expect(
        deletion.applying(acceptedHunkIDs: [0])
            == "开头\n结尾"
    )
}

@Test func aiEditPatchChangesOnlyReturnedPassages() throws {
    let original = """
    # 标题

    第一段保持不变。

    第二段需要润色。

    结尾保持不变。
    """
    let response = """
    {
      "edits": [
        {
          "old_text": "第二段需要润色。",
          "new_text": "第二段已经写得更清楚。"
        }
      ]
    }
    """

    let result = try AIEditPatchProcessor.apply(
        response: response,
        to: original
    )
    #expect(result.contains("第一段保持不变。"))
    #expect(result.contains("第二段已经写得更清楚。"))
    #expect(result.contains("结尾保持不变。"))
    #expect(!result.contains("第二段需要润色。"))
}

@Test func aiEditPatchSupportsDeletionAndAnchoredInsertion() throws {
    let original = "开头\n删除这一行\n结尾"
    let response = """
    {"edits":[
      {"old_text":"删除这一行\\n","new_text":""},
      {"old_text":"结尾","new_text":"新增一行\\n结尾"}
    ]}
    """

    #expect(
        try AIEditPatchProcessor.apply(response: response, to: original)
            == "开头\n新增一行\n结尾"
    )
}

@Test func aiEditPatchRejectsAmbiguousOrOverlappingPassages() {
    let ambiguous = """
    {"edits":[{"old_text":"重复","new_text":"替换"}]}
    """
    #expect(throws: Error.self) {
        try AIEditPatchProcessor.apply(
            response: ambiguous,
            to: "重复内容，重复出现。"
        )
    }

    let overlapping = AIEditPatch(edits: [
        AITextEdit(oldText: "甲乙", newText: "一"),
        AITextEdit(oldText: "乙丙", newText: "二"),
    ])
    #expect(throws: Error.self) {
        try AIEditPatchProcessor.apply(
            patch: overlapping,
            to: "甲乙丙"
        )
    }
}

@Test func chatEditPatchIsRemovedFromVisibleReplyAndAppliedLocally() throws {
    let response = """
    我只调整了第二段。

    ```edit-patch
    {"edits":[{"old_text":"旧段落","new_text":"新段落"}]}
    ```
    """
    let extracted = try AIEditPatchProcessor.extractFromChat(
        response,
        original: "开头\n旧段落\n结尾"
    )

    #expect(extracted.display == "我只调整了第二段。")
    #expect(extracted.replacement == "开头\n新段落\n结尾")
}

@Test func aiEditPatchPreservesScopeAndReasonForConfirmation() throws {
    let response = """
    {"edits":[
      {"old_text":"选区","new_text":"选区修改","scope":"selection","reason":null},
      {"old_text":"相邻句","new_text":"调整后的相邻句","scope":"context","reason":"需要与新表述保持主语一致"}
    ]}
    """
    let application = try AIEditPatchProcessor.applyDetailed(
        response: response,
        to: "选区\n相邻句"
    )

    #expect(application.edits.count == 2)
    #expect(application.edits[0].scope == "selection")
    #expect(application.edits[1].scope == "context")
    #expect(application.edits[1].reason == "需要与新表述保持主语一致")
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
    #expect(AIEndpointResolver.chatCompletionsURL(from: "not a URL") == nil)
}

@Test func documentOpenRequestKeepsEverySelectedFileInTheCurrentLibrary() throws {
    let root = URL(filePath: "/tmp/ZhijingOpenLibrary", directoryHint: .isDirectory)
    let resolved = DocumentOpenRequestResolver.resolve(
        urls: [
            root.appending(path: "第一篇.md"),
            root.appending(path: "资料/第二篇.txt"),
            root.appending(path: "第一篇.md"),
        ],
        currentLibrary: root
    )
    let request = try #require(resolved)

    #expect(request.root == root.standardizedFileURL)
    #expect(request.relativePaths == ["第一篇.md", "资料/第二篇.txt"])
    #expect(request.externalURLs.isEmpty)
}

@Test func documentOpenRequestKeepsOtherFoldersAsExternalDocuments() throws {
    let first = URL(filePath: "/tmp/ZhijingOne/第一篇.md")
    let second = URL(filePath: "/tmp/ZhijingTwo/第二篇.md")
    let request = try #require(DocumentOpenRequestResolver.resolve(
        urls: [first, second],
        currentLibrary: nil
    ))

    #expect(request.root == first.deletingLastPathComponent().standardizedFileURL)
    #expect(request.relativePaths == ["第一篇.md"])
    #expect(request.externalURLs == [second.standardizedFileURL])
    #expect(request.firstURL == first.standardizedFileURL)
}

@Test func documentsWithTheSameRelativeNameUseDifferentAbsoluteIdentities() {
    let first = NoteDocument(
        url: URL(filePath: "/tmp/ZhijingOne/README.md"),
        relativePath: "README.md",
        modifiedAt: .distantPast,
        size: 0
    )
    let second = NoteDocument(
        url: URL(filePath: "/tmp/ZhijingTwo/README.md"),
        relativePath: "README.md",
        modifiedAt: .distantPast,
        size: 0
    )

    #expect(first.id != second.id)
}

@Test func libraryTreeFollowsTheRealNestedFolderStructure() {
    let documents = [
        NoteDocument(
            url: URL(filePath: "/tmp/library/根目录.md"),
            relativePath: "根目录.md",
            modifiedAt: .distantPast,
            size: 0
        ),
        NoteDocument(
            url: URL(filePath: "/tmp/library/稿子/第一期/大纲.md"),
            relativePath: "稿子/第一期/大纲.md",
            modifiedAt: .distantPast,
            size: 0
        ),
        NoteDocument(
            url: URL(filePath: "/tmp/library/稿子/第一期/最终版/正文.md"),
            relativePath: "稿子/第一期/最终版/正文.md",
            modifiedAt: .distantPast,
            size: 0
        ),
    ]

    let tree = LibraryTreeBuilder.build(
        folders: ["稿子", "稿子/第一期", "稿子/第一期/最终版", "稿子/空文件夹"],
        documents: documents
    )

    func snapshot(_ items: [LibraryTreeItem], depth: Int = 0) -> [String] {
        items.flatMap { item in
            let prefix = String(repeating: "  ", count: depth)
            switch item.content {
            case .folder(let path):
                return ["\(prefix)F:\(path)"]
                    + snapshot(item.children ?? [], depth: depth + 1)
            case .document(let document):
                return ["\(prefix)D:\(document.relativePath)"]
            }
        }
    }

    #expect(snapshot(tree) == [
        "F:稿子",
        "  F:稿子/第一期",
        "    F:稿子/第一期/最终版",
        "      D:稿子/第一期/最终版/正文.md",
        "    D:稿子/第一期/大纲.md",
        "  F:稿子/空文件夹",
        "D:根目录.md",
    ])
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

@Test func searchReloadsContentAfterAnExternalFileChange() throws {
    let root = URL(filePath: NSTemporaryDirectory())
        .appending(path: "ZhijingExternalSearch-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let noteURL = root.appending(path: "笔记.md")
    try "旧关键词只在这里出现".write(to: noteURL, atomically: true, encoding: .utf8)
    let service = KnowledgeBaseService()
    let originalDocuments = try service.scan(root: root, excludedFolders: [])
    #expect(!service.search(query: "旧关键词", documents: originalDocuments).isEmpty)

    try "新的检索词已经写入外部版本，长度也不同。".write(
        to: noteURL,
        atomically: true,
        encoding: .utf8
    )
    let refreshedDocuments = try service.scan(root: root, excludedFolders: [])
    #expect(!service.search(query: "新的检索词", documents: refreshedDocuments).isEmpty)
    #expect(service.search(query: "旧关键词", documents: refreshedDocuments).isEmpty)
}

@Test func savingReturnsFreshMetadataAndKeepsTheSearchCacheCurrent() throws {
    let root = URL(filePath: NSTemporaryDirectory())
        .appending(path: "ZhijingSaveMetadata-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let noteURL = root.appending(path: "笔记.md")
    try "遗留标识甲乙".write(to: noteURL, atomically: true, encoding: .utf8)
    let service = KnowledgeBaseService()
    let original = try #require(service.scan(root: root, excludedFolders: []).first)
    let refreshed = try service.write("新的可搜索内容", to: original)

    #expect(refreshed.size == "新的可搜索内容".utf8.count)
    #expect(!service.search(query: "新的可搜索", documents: [refreshed]).isEmpty)
    #expect(service.search(query: "遗留标识", documents: [refreshed]).isEmpty)
}

@Test func searchCacheDoesNotLeakAcrossLibrariesWithMatchingFileSignatures() throws {
    let root = URL(filePath: NSTemporaryDirectory())
        .appending(path: "ZhijingLibraries-\(UUID().uuidString)", directoryHint: .isDirectory)
    let firstLibrary = root.appending(path: "First", directoryHint: .isDirectory)
    let secondLibrary = root.appending(path: "Second", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: firstLibrary, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondLibrary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let firstURL = firstLibrary.appending(path: "笔记.md")
    let secondURL = secondLibrary.appending(path: "笔记.md")
    try "甲库内容".write(to: firstURL, atomically: true, encoding: .utf8)
    try "乙库内容".write(to: secondURL, atomically: true, encoding: .utf8)
    let matchingDate = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes([.modificationDate: matchingDate], ofItemAtPath: firstURL.path)
    try FileManager.default.setAttributes([.modificationDate: matchingDate], ofItemAtPath: secondURL.path)

    let service = KnowledgeBaseService()
    let firstDocuments = try service.scan(root: firstLibrary, excludedFolders: [])
    #expect(!service.search(query: "甲库", documents: firstDocuments).isEmpty)

    let secondDocuments = try service.scan(root: secondLibrary, excludedFolders: [])
    #expect(service.search(query: "甲库", documents: secondDocuments).isEmpty)
    #expect(!service.search(query: "乙库", documents: secondDocuments).isEmpty)
}

@Test func currentQuestionAppearsOnlyOnceInAIRequestMessages() {
    let question = "这次问题"
    let history = [
        ChatMessage(role: .user, text: "上一次问题"),
        ChatMessage(role: .assistant, text: "上一次回答"),
        ChatMessage(role: .user, text: question),
    ]
    let messages = AIService().answerMessages(
        question: question,
        currentContext: "正文",
        history: history,
        sources: []
    )
    #expect(messages.filter { $0["role"] == "user" && $0["content"] == question }.count == 1)
}

@Test func libraryWatcherFiltersExcludedFolderEvents() {
    let root = "/tmp/ZhijingWatch"
    #expect(LibraryWatcher.shouldInclude(
        URL(filePath: root + "/文章.md"),
        rootPath: root,
        excludedFolders: [".git", "node_modules"]
    ))
    #expect(!LibraryWatcher.shouldInclude(
        URL(filePath: root + "/node_modules/pkg/index.txt"),
        rootPath: root,
        excludedFolders: [".git", "node_modules"]
    ))
    #expect(!LibraryWatcher.shouldInclude(
        URL(filePath: "/tmp/Other/文章.md"),
        rootPath: root,
        excludedFolders: [".git", "node_modules"]
    ))
}

@Test func chatsPersistOutsideUserDefaultsAndKeepLatestSnapshot() throws {
    let root = URL(filePath: NSTemporaryDirectory())
        .appending(path: "ZhijingChats-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = ChatPersistenceService(directoryOverride: root)
    persistence.save(["文章.md": [ChatMessage(role: .user, text: "旧消息")]])
    let latest = ["文章.md": [ChatMessage(role: .user, text: "新消息")]]
    try persistence.saveSynchronously(latest)

    let loaded = persistence.load()
    #expect(loaded["文章.md"]?.map(\.text) == ["新消息"])
}

@Test func documentStateKeysDoNotLeakAcrossLibraries() {
    let first = NoteDocument(
        url: URL(filePath: "/tmp/FirstLibrary/共享.md"),
        relativePath: "共享.md",
        modifiedAt: .distantPast,
        size: 0
    )
    let second = NoteDocument(
        url: URL(filePath: "/tmp/SecondLibrary/共享.md"),
        relativePath: "共享.md",
        modifiedAt: .distantPast,
        size: 0
    )
    let message = ChatMessage(role: .user, text: "只属于第一个知识库")

    let migrated = DocumentStateStore.migrateLegacyKeys(
        favorites: ["共享.md"],
        chats: ["共享.md": [message]],
        documents: [first]
    )

    #expect(first.persistenceKey != second.persistenceKey)
    #expect(migrated.favorites == [first.persistenceKey])
    #expect(migrated.chats[first.persistenceKey] == [message])
    #expect(migrated.chats[second.persistenceKey] == nil)

    let afterSwitch = DocumentStateStore.migrateLegacyKeys(
        favorites: migrated.favorites,
        chats: migrated.chats,
        documents: [second]
    )
    #expect(!afterSwitch.didChange)
    #expect(afterSwitch.favorites == [first.persistenceKey])
    #expect(afterSwitch.chats[second.persistenceKey] == nil)
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

@Test func scanIncludesSRTSubtitles() throws {
    let root = URL(filePath: NSTemporaryDirectory())
        .appending(path: "ZhijingSRT-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try """
    1
    00:00:01,000 --> 00:00:03,000
    你好，知境。
    """.write(
        to: root.appending(path: "字幕.srt"),
        atomically: true,
        encoding: .utf8
    )

    let documents = try KnowledgeBaseService().scan(root: root, excludedFolders: [])
    #expect(documents.map(\.relativePath) == ["字幕.srt"])
}

@Test func foldersCanBeRenamedAndDocumentsMovedWithoutChangingContents() throws {
    let root = URL(filePath: NSTemporaryDirectory())
        .appending(path: "ZhijingMove-\(UUID().uuidString)", directoryHint: .isDirectory)
    let originalFolder = root.appending(path: "原文件夹", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: originalFolder,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try "保留的正文".write(
        to: originalFolder.appending(path: "文章.md"),
        atomically: true,
        encoding: .utf8
    )

    let service = KnowledgeBaseService()
    _ = try service.renameFolder(
        root: root,
        relativePath: "原文件夹",
        to: "新文件夹"
    )
    let renamedDocument = try #require(
        service.scan(root: root, excludedFolders: []).first
    )
    #expect(renamedDocument.relativePath == "新文件夹/文章.md")

    let movedURL = try service.move(
        renamedDocument,
        toFolder: "",
        root: root
    )
    #expect(movedURL.lastPathComponent == "文章.md")
    #expect(try String(contentsOf: movedURL, encoding: .utf8) == "保留的正文")
}

@Test func scanFoldersIncludesEmptyAndNestedFolders() throws {
    let root = URL(filePath: NSTemporaryDirectory())
        .appending(path: "ZhijingFolders-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: root.appending(path: "空文件夹/子文件夹", directoryHint: .isDirectory),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let folders = try KnowledgeBaseService().scanFolders(
        root: root,
        excludedFolders: []
    )
    #expect(folders == ["空文件夹", "空文件夹/子文件夹"])
}

@Test func onePassLibraryScanReturnsDocumentsFoldersAndExclusions() throws {
    let root = URL(filePath: NSTemporaryDirectory())
        .appending(path: "ZhijingOnePassScan-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: root.appending(path: "内容/空目录", directoryHint: .isDirectory),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: root.appending(path: "node_modules/pkg", directoryHint: .isDirectory),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try "正文".write(
        to: root.appending(path: "内容/文章.md"),
        atomically: true,
        encoding: .utf8
    )
    try "不应扫描".write(
        to: root.appending(path: "node_modules/pkg/忽略.md"),
        atomically: true,
        encoding: .utf8
    )

    let result = try KnowledgeBaseService().scanLibrary(
        root: root,
        excludedFolders: ["node_modules"]
    )

    #expect(result.documents.map(\.relativePath) == ["内容/文章.md"])
    #expect(result.folders == ["内容", "内容/空目录"])
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

@Test func editProposalsDistinguishAssistantAndExternalFileChanges() {
    let assistant = EditProposal(
        documentPath: "文章.md",
        original: "原稿",
        replacement: "AI 修改",
        instruction: "润色"
    )
    let external = EditProposal(
        documentPath: "文章.md",
        original: "原稿",
        replacement: "外部 AI 修改",
        instruction: "外部修改",
        source: .externalFile
    )

    #expect(assistant.source == .assistant)
    #expect(external.source == .externalFile)
    #expect(SaveState.reviewingExternalChange.label == "等待确认外部修改")
}

@MainActor
@Test func editorIgnoresObservableFeedbackUntilContentRevisionChanges() {
    let textView = MarkdownEditorTextView()
    let coordinator = MarkdownSourceEditor.Coordinator(onChange: { _ in })
    coordinator.synchronize(
        text: "初始内容",
        documentID: "文章.md",
        contentRevision: 1,
        to: textView
    )
    textView.setSelectedRange(NSRange(location: 2, length: 0))

    coordinator.synchronize(
        text: "SwiftUI 回传但不是外部修改",
        documentID: "文章.md",
        contentRevision: 1,
        to: textView
    )
    #expect(textView.string == "初始内容")
    #expect(textView.selectedRange() == NSRange(location: 2, length: 0))

    coordinator.synchronize(
        text: "明确的外部修改",
        documentID: "文章.md",
        contentRevision: 2,
        to: textView
    )
    #expect(textView.string == "明确的外部修改")
    #expect(textView.selectedRange() == NSRange(location: 2, length: 0))
}

@MainActor
@Test func editorTabsRestoreEachDocumentsSelection() {
    let textView = MarkdownEditorTextView()
    let coordinator = MarkdownSourceEditor.Coordinator(onChange: { _ in })

    coordinator.synchronize(
        text: "第一篇文稿内容",
        documentID: "第一篇.md",
        contentRevision: 1,
        to: textView
    )
    textView.setSelectedRange(NSRange(location: 4, length: 0))

    coordinator.synchronize(
        text: "第二篇文稿内容",
        documentID: "第二篇.md",
        contentRevision: 1,
        to: textView
    )
    textView.setSelectedRange(NSRange(location: 2, length: 0))

    coordinator.synchronize(
        text: "第一篇文稿内容",
        documentID: "第一篇.md",
        contentRevision: 1,
        to: textView
    )
    #expect(textView.selectedRange() == NSRange(location: 4, length: 0))

    coordinator.synchronize(
        text: "第二篇文稿内容",
        documentID: "第二篇.md",
        contentRevision: 1,
        to: textView
    )
    #expect(textView.selectedRange() == NSRange(location: 2, length: 0))
}

@MainActor
@Test func editorNavigationSelectsTheRequestedSourceLine() {
    let textView = MarkdownEditorTextView()
    let coordinator = MarkdownSourceEditor.Coordinator(onChange: { _ in })
    coordinator.synchronize(
        text: "第一行\n第二行\n需要定位的第三行\n第四行",
        documentID: "来源.md",
        contentRevision: 1,
        to: textView
    )
    coordinator.navigate(
        to: EditorNavigationRequest(
            documentID: "来源.md",
            line: 3
        ),
        in: textView
    )

    let selected = (textView.string as NSString).substring(
        with: textView.selectedRange()
    )
    #expect(selected == "需要定位的第三行")
}

@MainActor
@Test func editorReportsAConcreteTextSelectionToSwiftUI() {
    let textView = MarkdownEditorTextView()
    var reported: EditorTextSelection?
    let coordinator = MarkdownSourceEditor.Coordinator(
        onChange: { _ in },
        onSelectionChange: { reported = $0 }
    )
    textView.delegate = coordinator
    coordinator.synchronize(
        text: "前文\n需要修改的文字\n后文",
        documentID: "文章.md",
        contentRevision: 1,
        to: textView
    )
    let range = (textView.string as NSString).range(of: "需要修改的文字")
    textView.setSelectedRange(range)
    coordinator.textViewDidChangeSelection(
        Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
    )

    #expect(reported?.documentID == "文章.md")
    #expect(reported?.range == range)
    #expect(reported?.text == "需要修改的文字")
}

@MainActor
@Test func continuousTypingCannotCreateAParagraphBreakOrMoveTheCaret() {
    let initial = "这一行正在连续输入："
    let typed = String(repeating: "连续输入abcdef", count: 20)
    let scrollView = NSScrollView(
        frame: NSRect(x: 0, y: 0, width: 260, height: 180)
    )
    let textView = MarkdownEditorTextView(frame: scrollView.contentView.bounds)
    textView.isRichText = false
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.containerSize = NSSize(
        width: scrollView.contentSize.width,
        height: CGFloat.greatestFiniteMagnitude
    )
    textView.textContainer?.widthTracksTextView = true
    MarkdownSourceEditor.Coordinator.applyPlainTextAppearance(to: textView)
    scrollView.documentView = textView
    let coordinator = MarkdownSourceEditor.Coordinator(onChange: { _ in })
    textView.delegate = coordinator
    coordinator.synchronize(
        text: initial,
        documentID: "连续输入.md",
        contentRevision: 1,
        to: textView
    )
    textView.setSelectedRange(
        NSRange(location: initial.utf16.count, length: 0)
    )
    let initialNewlineCount = textView.string.filter(\.isNewline).count

    for character in typed {
        let previousLocation = textView.selectedRange().location
        textView.insertText(
            String(character),
            replacementRange: textView.selectedRange()
        )
        MarkdownPresentationHighlighter.apply(to: textView)
        coordinator.synchronize(
            text: textView.string,
            documentID: "连续输入.md",
            contentRevision: 1,
            to: textView
        )
        textView.layoutManager?.ensureLayout(
            for: textView.textContainer!
        )
        #expect(textView.selectedRange().location == previousLocation + 1)
        #expect(textView.string.filter(\.isNewline).count == initialNewlineCount)
    }

    #expect(textView.string == initial + typed)
    #expect((textView.layoutManager?.numberOfGlyphs ?? 0) == textView.string.utf16.count)
}

@MainActor
@Test func markdownLinksStayOutsideTheNativeTextStorage() {
    let source = "[OpenAI](https://openai.com)"
    let textView = MarkdownEditorTextView()
    textView.string = source
    textView.markdownLinks = MarkdownLinkDetector.links(in: source)

    #expect(textView.markdownLinks.count == 1)
    #expect(textView.markdownLinks.first?.url.absoluteString == "https://openai.com")
    #expect(textView.textStorage?.attribute(.link, at: 1, effectiveRange: nil) == nil)
}

@MainActor
@Test func presentationHighlightingUsesOnlyNonMetricTemporaryAttributes() {
    let source = """
    # 标题
    > 引用
    - 列表
    **重点**与`代码`
    [链接](https://example.com)
    """
    let textView = MarkdownEditorTextView()
    textView.isRichText = false
    textView.string = source
    MarkdownSourceEditor.Coordinator.applyPlainTextAppearance(to: textView)
    MarkdownPresentationHighlighter.apply(to: textView)

    guard let layoutManager = textView.layoutManager else {
        Issue.record("编辑器缺少布局管理器")
        return
    }
    for index in 0..<source.utf16.count {
        let attributes = layoutManager.temporaryAttributes(
            atCharacterIndex: index,
            effectiveRange: nil
        )
        #expect(attributes[.font] == nil)
        #expect(attributes[.paragraphStyle] == nil)
        #expect(attributes[.link] == nil)
    }
    #expect(
        layoutManager.temporaryAttributes(
            atCharacterIndex: 2,
            effectiveRange: nil
        )[.foregroundColor] != nil
    )
}

@MainActor
@Test func linkPointerRectsUseTextViewCoordinatesAndFollowWrappedLines() {
    let source = "[一个很长的可点击链接文字用于换行测试](https://example.com)"
    let scrollView = NSScrollView(
        frame: NSRect(x: 0, y: 0, width: 150, height: 160)
    )
    let textView = MarkdownEditorTextView(frame: scrollView.contentView.bounds)
    textView.textContainerInset = NSSize(width: 22, height: 24)
    textView.isHorizontallyResizable = false
    textView.textContainer?.containerSize = NSSize(
        width: scrollView.contentSize.width,
        height: CGFloat.greatestFiniteMagnitude
    )
    textView.textContainer?.widthTracksTextView = true
    textView.string = source
    MarkdownSourceEditor.Coordinator.applyPlainTextAppearance(to: textView)
    scrollView.documentView = textView

    guard let link = MarkdownLinkDetector.links(in: source).first,
          let layoutManager = textView.layoutManager,
          let textContainer = textView.textContainer else {
        Issue.record("无法建立链接布局测试")
        return
    }
    textView.markdownLinks = [link]
    layoutManager.ensureLayout(for: textContainer)
    let rects = textView.cursorRects(
        for: link.range,
        layoutManager: layoutManager,
        textContainer: textContainer
    )

    #expect(rects.count > 1)
    #expect(rects.allSatisfy { $0.minX >= textView.textContainerOrigin.x })
    #expect(rects.first?.minY == textView.textContainerOrigin.y)
    if let firstRect = rects.first {
        #expect(textView.markdownLink(at: NSPoint(
            x: firstRect.midX,
            y: firstRect.midY
        )) == link)
    }
    #expect(textView.markdownLink(at: NSPoint(x: 1, y: 1)) == nil)
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

@Test func namedSnapshotsPersistMetadataAndRemainUnique() throws {
    let root = URL(filePath: NSTemporaryDirectory())
        .appending(path: "ZhijingVersions-\(UUID().uuidString)", directoryHint: .isDirectory)
    let library = root.appending(path: "Library", directoryHint: .isDirectory)
    let support = root.appending(path: "Support", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let noteURL = library.appending(path: "计划.md")
    try "第一版".write(to: noteURL, atomically: true, encoding: .utf8)
    let document = NoteDocument(
        url: noteURL,
        relativePath: "计划.md",
        modifiedAt: .now,
        size: 9
    )
    let service = KnowledgeBaseService(supportDirectoryOverride: support)

    _ = try service.createSnapshot(
        text: "第一版",
        document: document,
        name: "完成初稿"
    )
    _ = try service.createSnapshot(
        text: "第二版",
        document: document,
        name: "结构调整"
    )

    let revisions = service.revisions(for: document)
    #expect(revisions.count == 2)
    #expect(Set(revisions.compactMap(\.name)) == ["完成初稿", "结构调整"])
    #expect(Set(try revisions.map(service.revisionText)) == ["第一版", "第二版"])
    #expect(Set(revisions.map(\.url)).count == 2)
}

@Test func snapshotsWithMatchingRelativePathsStayInTheirOwnLibraries() throws {
    let root = URL(filePath: NSTemporaryDirectory())
        .appending(path: "ZhijingVersionIsolation-\(UUID().uuidString)", directoryHint: .isDirectory)
    let firstLibrary = root.appending(path: "First", directoryHint: .isDirectory)
    let secondLibrary = root.appending(path: "Second", directoryHint: .isDirectory)
    let support = root.appending(path: "Support", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: firstLibrary, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondLibrary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let first = NoteDocument(
        url: firstLibrary.appending(path: "共享.md"),
        relativePath: "共享.md",
        modifiedAt: .now,
        size: 0
    )
    let second = NoteDocument(
        url: secondLibrary.appending(path: "共享.md"),
        relativePath: "共享.md",
        modifiedAt: .now,
        size: 0
    )
    let service = KnowledgeBaseService(supportDirectoryOverride: support)

    _ = try service.createSnapshot(text: "第一库版本", document: first)
    _ = try service.createSnapshot(text: "第二库版本", document: second)

    #expect(try service.revisions(for: first).map(service.revisionText) == ["第一库版本"])
    #expect(try service.revisions(for: second).map(service.revisionText) == ["第二库版本"])
}

@Test func snapshotsFollowAFileRenameWithoutLosingMetadata() throws {
    let root = URL(filePath: NSTemporaryDirectory())
        .appending(path: "ZhijingVersionMove-\(UUID().uuidString)", directoryHint: .isDirectory)
    let library = root.appending(path: "Library", directoryHint: .isDirectory)
    let support = root.appending(path: "Support", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let originalURL = library.appending(path: "原名.md")
    try "正文".write(to: originalURL, atomically: true, encoding: .utf8)
    let original = NoteDocument(
        url: originalURL,
        relativePath: "原名.md",
        modifiedAt: .now,
        size: 0
    )
    let service = KnowledgeBaseService(supportDirectoryOverride: support)
    _ = try service.createSnapshot(text: "历史正文", document: original, name: "重命名前")

    let destination = try service.rename(original, to: "新名")
    try service.migrateRevisions(from: original, to: destination)
    let renamed = NoteDocument(
        url: destination,
        relativePath: "新名.md",
        modifiedAt: .now,
        size: 0
    )
    let revisions = service.revisions(for: renamed)

    #expect(revisions.map(\.name) == ["重命名前"])
    #expect(try revisions.map(service.revisionText) == ["历史正文"])
}

@Test func externalFileChangesAreReconciledWithoutOverwritingEitherSide() {
    #expect(
        ExternalFileReconciler.evaluate(
            loadedText: "基线",
            editorText: "本地修改",
            diskText: "基线"
        ) == .localChangesOnly
    )
    #expect(
        ExternalFileReconciler.evaluate(
            loadedText: "基线",
            editorText: "基线",
            diskText: "外部修改"
        ) == .reloadFromDisk("外部修改")
    )
    #expect(
        ExternalFileReconciler.evaluate(
            loadedText: "基线",
            editorText: "本地修改",
            diskText: "外部修改"
        ) == .conflict("外部修改")
    )
    #expect(
        ExternalFileReconciler.evaluate(
            loadedText: "基线",
            editorText: "本地修改",
            diskText: nil
        ) == .removedWithLocalChanges
    )
}

@Test func documentMetricsIgnoreMarkdownMarkers() {
    let short = DocumentMetrics(markdown: "# 标题\n\n你好 **world**")
    #expect(short.count == 5)

    let long = DocumentMetrics(markdown: String(repeating: "知", count: 501))
    #expect(long.count == 501)
}

@Test func persistedPaneWidthsAreAlwaysUsable() {
    #expect(PaneWidthPreference.clamped(nil, default: 260, range: 210...360) == 260)
    #expect(PaneWidthPreference.clamped(.nan, default: 260, range: 210...360) == 260)
    #expect(PaneWidthPreference.clamped(40, default: 260, range: 210...360) == 210)
    #expect(PaneWidthPreference.clamped(900, default: 260, range: 210...360) == 360)
    #expect(PaneWidthPreference.clamped(280, default: 260, range: 210...360) == 280)
}

@Test func documentFindMatchesCaseAndWholeWordOptions() {
    let source = "Alpha alpha alphabet\n中文中文 alpha_2 alpha"

    let insensitive = DocumentFindMatcher.matches(
        in: source,
        options: DocumentFindOptions(query: "alpha")
    )
    #expect(insensitive.count == 5)

    let caseSensitive = DocumentFindMatcher.matches(
        in: source,
        options: DocumentFindOptions(query: "alpha", matchCase: true)
    )
    #expect(caseSensitive.count == 4)

    let wholeWord = DocumentFindMatcher.matches(
        in: source,
        options: DocumentFindOptions(query: "alpha", wholeWord: true)
    )
    #expect(wholeWord.count == 3)
    #expect(wholeWord.allSatisfy {
        (source as NSString)
            .substring(with: $0)
            .localizedCaseInsensitiveCompare("alpha") == .orderedSame
    })
}

@MainActor
@Test func pdfAndWordExportsProduceReadableDocuments() throws {
    let requestedDirectory = ProcessInfo.processInfo.environment["ZHIJING_EXPORT_QA_DIR"]
    let root = requestedDirectory.map {
        URL(filePath: $0, directoryHint: .isDirectory)
    } ?? URL(filePath: NSTemporaryDirectory())
        .appending(path: "ZhijingExports-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        if requestedDirectory == nil {
            try? FileManager.default.removeItem(at: root)
        }
    }

    let repeatedSections = (1...24).map { index in
        """
        ## 分页测试 \(index)

        这一段用于验证长文档能够跨页导出，并且后续页面仍然保留稳定的边距、字号和行距。
        """
    }.joined(separator: "\n\n")
    let markdown = """
    # 导出测试

    这是用于验证中文排版的正文，包含 **重点内容** 与 [链接](https://example.com)。

    > 引用内容应该保持清晰的层级。

    - 第一项
    - 第二项

    ```swift
    let message = "hello"
    ```

    \(repeatedSections)
    """
    let pdfURL = root.appending(path: "知境导出测试.pdf")
    let wordURL = root.appending(path: "知境导出测试.docx")
    let exporter = DocumentExportService()

    try exporter.export(
        title: "知境导出测试",
        markdown: markdown,
        format: .pdf,
        to: pdfURL
    )
    try exporter.export(
        title: "知境导出测试",
        markdown: markdown,
        format: .word,
        to: wordURL
    )

    #expect((try Data(contentsOf: pdfURL)).starts(with: Data("%PDF".utf8)))
    #expect(PDFDocument(url: pdfURL)?.pageCount ?? 0 >= 2)
    #expect((try Data(contentsOf: wordURL)).starts(with: Data([0x50, 0x4B])))
    #expect((try wordURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 1_000)
}
