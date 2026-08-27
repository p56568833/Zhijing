import Foundation
import Testing
@testable import Zhijing

private final class InertLibraryWatcher: LibraryWatching {
    func start(
        root: URL,
        additionalFiles: [URL],
        excludedFolders: [String],
        onChange: @escaping @Sendable ([URL]) -> Void
    ) {}

    func stop() {}
}

@MainActor
@Test func appPreferencesOwnsDefaultsPersistence() throws {
    let suite = "AppPreferencesTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferencesController(defaults: defaults)

    preferences.favorites.insert("/tmp/favorite.md")
    preferences.colorScheme = .dark
    preferences.excludedFoldersText = ".git, build"

    #expect(defaults.stringArray(forKey: "favorites") == ["/tmp/favorite.md"])
    #expect(defaults.string(forKey: "colorScheme") == "dark")
    #expect(defaults.string(forKey: "excludedFolders") == ".git, build")
}

@MainActor
@Test func workspaceNavigationOwnsTabsAndComparisonPersistence() throws {
    let suite = "WorkspaceNavigationTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["one.md"], forKey: "openDocumentPaths")
    defaults.set(true, forKey: "comparisonVisible")
    defaults.set("two.md", forKey: "comparisonDocumentPath")
    let controller = WorkspaceNavigationController(defaults: defaults)
    let documents = [
        NoteDocument(
            url: URL(filePath: "/tmp/one.md"),
            relativePath: "one.md",
            modifiedAt: .now,
            size: 0
        ),
        NoteDocument(
            url: URL(filePath: "/tmp/two.md"),
            relativePath: "two.md",
            modifiedAt: .now,
            size: 0
        ),
    ]

    #expect(controller.openDocuments(in: documents) == [documents[0]])
    #expect(controller.isComparisonVisible)
    #expect(controller.comparisonDocumentPath == "two.md")

    controller.resetForLibraryTransition()
    #expect(controller.openDocumentPaths.isEmpty)
    #expect(controller.comparisonDocumentPath == nil)
    #expect(defaults.stringArray(forKey: "openDocumentPaths") == nil)
    #expect(defaults.bool(forKey: "comparisonVisible") == false)
}

@MainActor
@Test func annotationControllerOwnsMutationAndReanchoring() throws {
    let document = NoteDocument(
        url: URL(filePath: "/tmp/annotation-controller.md"),
        relativePath: "annotation-controller.md",
        modifiedAt: .now,
        size: 0
    )
    let original = "hello world"
    let selection = EditorTextSelection(
        documentID: document.id,
        range: NSRange(location: 6, length: 5),
        text: "world"
    )
    let controller = AnnotationController()

    #expect(controller.add(
        text: "重点",
        selection: selection,
        document: document,
        documentText: original
    ))
    let annotation = try #require(controller.annotations(for: document).first)
    #expect(controller.toggleResolution(id: annotation.id, document: document))
    #expect(controller.annotations(for: document).first?.isResolved == true)

    let changed = "hello brave world"
    #expect(controller.reanchor(
        document: document,
        from: original,
        to: changed,
        mutation: nil
    ))
    let resolved = controller.resolution(for: document, text: changed)
    #expect(resolved.resolved.first?.annotation.anchor.selectedText == "world")
}

@MainActor
@Test func editorSessionStateOwnsEditorIdentityAndMetrics() async {
    let document = NoteDocument(
        url: URL(filePath: "/tmp/editor-state.md"),
        relativePath: "editor-state.md",
        modifiedAt: .now,
        size: 0
    )
    let state = EditorSessionState()
    state.selectedDocument = document
    state.replaceText("你好 world")
    await state.waitForWordCountUpdate()

    #expect(state.selectedDocument == document)
    #expect(state.text == "你好 world")
    #expect(state.contentRevision == 1)
    #expect(state.wordCount == DocumentMetrics(markdown: "你好 world").count)
    #expect(state.speakingDurationLabel == "不足 1 分钟")

    state.updateSelection(EditorTextSelection(
        documentID: document.id,
        range: NSRange(location: 0, length: 2),
        text: "你好"
    ))
    #expect(state.selectionMetrics?.count == 2)
    #expect(state.selectionMetrics?.speakingDurationLabel == "不足 1 分钟")

    state.updateMetricSelection("阅读模式中的选区")
    #expect(state.selectionMetrics?.count == 8)
    state.updateMetricSelection(nil)
    #expect(state.selectionMetrics == nil)

    state.clearDocument()
    #expect(state.selectedDocument == nil)
    #expect(state.text.isEmpty)
    #expect(state.contentRevision == 2)
    #expect(state.wordCount == 0)
    #expect(state.selectionMetrics == nil)
}

@MainActor
@Test func externalChangeMonitorCoalescesPendingPaths() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "ExternalChangeMonitorTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appending(path: "first.md")
    let second = root.appending(path: "second.md")
    var received: Set<URL> = []
    let monitor = ExternalChangeMonitor(
        watcher: InertLibraryWatcher(),
        debounceDelay: .zero
    )
    monitor.start(
        libraryRoot: root,
        additionalFiles: [],
        excludedFolders: []
    ) { changedURLs in
        received = changedURLs
    }

    monitor.receive([first])
    monitor.receive([second])
    await monitor.waitForPendingChanges()

    #expect(received.contains(first.standardizedFileURL))
    #expect(received.contains(second.standardizedFileURL))
    monitor.stop()
}

@MainActor
@Test func externalConflictControllerEvaluatesAndLoadsDiskVersion() throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "ExternalConflictControllerTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let documentURL = root.appending(path: "note.md")
    try "外部新版".write(to: documentURL, atomically: true, encoding: .utf8)
    let document = NoteDocument(
        url: documentURL,
        relativePath: "note.md",
        modifiedAt: .now,
        size: 12
    )
    let service = KnowledgeBaseService(
        supportDirectoryOverride: root.appending(path: "Support")
    )
    let session = DocumentSessionController()
    session.loadedText = "原版"
    let revisions = RevisionController(service: service)
    let controller = ExternalConflictController(
        knowledgeBase: service,
        documentSession: session,
        revisions: revisions
    )

    let change = try controller.evaluateChange(
        for: document,
        editorText: "原版",
        changedURLs: [documentURL]
    )
    #expect(change == .reloadFromDisk("外部新版"))

    controller.recordConflict(
        document: document,
        localText: "本地改动",
        diskText: "外部新版"
    )
    let loaded = try controller.loadExternalVersion(editorText: "本地改动")
    #expect(loaded?.text == "外部新版")
    #expect(controller.conflict == nil)
    #expect(session.loadedText == "外部新版")
    #expect(revisions.revisions.contains { $0.name == "冲突前的本地版本" })
}

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
        replacement: replacement
    )
    try replacement.write(to: documentURL, atomically: true, encoding: .utf8)
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
    #expect(revisions.revisions.count == 2)
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
