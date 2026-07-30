import Foundation
import Testing
@testable import Zhijing

@MainActor
@Test func workspaceCatalogOwnsScanIndexesAndDerivedLists() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "WorkspaceCatalogTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    let folder = root.appending(path: "Folder", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: folder,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let documentURL = folder.appending(path: "note.md")
    try "正文".write(to: documentURL, atomically: true, encoding: .utf8)
    let controller = WorkspaceCatalogController(
        service: KnowledgeBaseService()
    )
    controller.transition(to: root)

    let scanned = try await controller.refresh(
        excludedFolders: [],
        favorites: [documentURL.standardizedFileURL.path]
    )

    let document = try #require(scanned?.documents.first)
    #expect(controller.document(at: "Folder/note.md")?.id == document.id)
    #expect(controller.isLibraryDocument(document))
    #expect(controller.favoriteDocuments.map(\.id) == [document.id])
    #expect(controller.recentDocuments.map(\.id) == [document.id])
    #expect(!controller.libraryTree.isEmpty)
    #expect(!controller.isIndexing)

    controller.transition(to: root.appending(path: "Other"))
    #expect(controller.documents.isEmpty)
    #expect(controller.document(at: "Folder/note.md") == nil)
}

@MainActor
@Test func editProposalControllerOwnsSnapshotsWritesAndCompletion() throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "EditProposalControllerTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let documentURL = root.appending(path: "note.md")
    let original = "标题\n旧内容\n结尾"
    let replacement = "标题\n新内容\n结尾"
    try original.write(to: documentURL, atomically: true, encoding: .utf8)
    let document = NoteDocument(
        url: documentURL,
        relativePath: "note.md",
        modifiedAt: .now,
        size: original.utf8.count
    )
    let service = KnowledgeBaseService(
        supportDirectoryOverride: root.appending(path: "Support")
    )
    let session = DocumentSessionController()
    session.loadedText = original
    let revisions = RevisionController(service: service)
    let controller = EditProposalController(
        knowledgeBase: service,
        documentSession: session,
        revisions: revisions
    )
    controller.proposal = EditProposal(
        documentPath: document.relativePath,
        original: original,
        replacement: replacement,
        instruction: "更新内容"
    )
    let hunk = try #require(
        LineDiff(original: original, replacement: replacement).hunks.first
    )

    let resolved = try controller.resolve(
        hunkID: hunk.id,
        accepted: true,
        document: document,
        currentText: original
    )
    let outcome = try #require(resolved)

    guard case .applied(let text, _, _, let isComplete, _) = outcome else {
        Issue.record("应返回已应用的提案结果")
        return
    }
    #expect(text == replacement)
    #expect(isComplete)
    #expect(controller.proposal == nil)
    #expect(session.loadedText == replacement)
    #expect(try String(contentsOf: documentURL, encoding: .utf8) == replacement)
    #expect(revisions.revisions.count == 1)
}

@MainActor
@Test func aiGenerationControllerOwnsChatMigrationAndPersistence() throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "AIGenerationControllerTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = ChatPersistenceService(directoryOverride: root)
    let legacyChats = [
        "/old.md": [ChatMessage(role: .user, text: "保留这段对话")]
    ]
    let legacyData = try JSONEncoder().encode(legacyChats)
    let controller = AIGenerationController(
        knowledgeBase: KnowledgeBaseService(),
        persistence: persistence
    )

    try controller.loadChats(legacyData: legacyData)
    controller.moveChat(from: "/old.md", to: "/new.md")
    try controller.saveSynchronously()

    let reloaded = AIGenerationController(
        knowledgeBase: KnowledgeBaseService(),
        persistence: persistence
    )
    try reloaded.loadChats(legacyData: nil)
    #expect(reloaded.messages(for: "/old.md").isEmpty)
    #expect(reloaded.messages(for: "/new.md").map(\.text) == ["保留这段对话"])

    reloaded.clearChat(for: "/new.md")
    try reloaded.saveSynchronously()
    #expect(reloaded.messages(for: "/new.md").isEmpty)
}

@MainActor
@Test func librarySearchControllerOwnsCancellationAndEmptyQueryState() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "LibrarySearchControllerTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let documentURL = root.appending(path: "note.md")
    let content = "架构重构的目标内容"
    try content.write(to: documentURL, atomically: true, encoding: .utf8)
    let document = NoteDocument(
        url: documentURL,
        relativePath: "note.md",
        modifiedAt: .now,
        size: content.utf8.count
    )
    let controller = LibrarySearchController(
        service: KnowledgeBaseService(),
        delay: .zero
    )

    controller.query = "架构"
    controller.perform(documents: [document])
    await controller.waitForPendingSearch()
    #expect(controller.results.map(\.document.id) == [document.id])

    controller.query = "   "
    controller.perform(documents: [document])
    #expect(controller.results.isEmpty)
}

@MainActor
@Test func revisionControllerCreatesBackupBeforePreparingRestore() throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "RevisionControllerTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let documentURL = root.appending(path: "note.md")
    let document = NoteDocument(
        url: documentURL,
        relativePath: "note.md",
        modifiedAt: .now,
        size: 0
    )
    let service = KnowledgeBaseService(
        supportDirectoryOverride: root.appending(path: "Support")
    )
    let controller = RevisionController(service: service)

    _ = try controller.createSnapshot(
        text: "第一版",
        document: document,
        name: "初稿"
    )
    let target = try #require(controller.revisions.first)
    let restored = try controller.prepareRestore(
        target,
        currentText: "第二版",
        document: document
    )

    #expect(restored == "第一版")
    #expect(controller.revisions.count == 2)
    #expect(controller.revisions.contains { $0.name == "恢复前自动备份" })
}

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
