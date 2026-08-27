import Testing
import Foundation
import AppKit
import PDFKit
@testable import Zhijing

@MainActor
@Test func appStoreAutosaveDoesNotOverlapItsInternalWriteTrackingAccess() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let url = root.appending(path: "自动保存.md")
    try "初始内容".write(to: url, atomically: true, encoding: .utf8)
    let suiteName = "ZhijingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = AppStore(defaults: defaults)
    let document = NoteDocument(
        url: url,
        relativePath: url.path,
        modifiedAt: .now,
        size: 0
    )
    store.select(document)

    for index in 0..<100 {
        store.editorDidChange("连续输入 \(index)")
    }
    for _ in 0..<100 {
        if case .saved = store.saveState,
           try String(contentsOf: url, encoding: .utf8) == "连续输入 99" {
            break
        }
        try await Task.sleep(for: .milliseconds(50))
    }

    #expect(try String(contentsOf: url, encoding: .utf8) == "连续输入 99")
    guard case .saved = store.saveState else {
        Issue.record("自动保存未完成")
        return
    }
}

@Test func textAnnotationsFollowTheirQuotedTextAfterNearbyEdits() throws {
    let original = "开头\n需要批注的结论\n结尾"
    let range = (original as NSString).range(of: "需要批注的结论")
    let selection = EditorTextSelection(
        documentID: "/tmp/note.md",
        range: range,
        text: "需要批注的结论"
    )
    let anchor = try #require(
        TextAnnotationAnchorResolver.makeAnchor(selection: selection, in: original)
    )
    let annotation = TextAnnotation(anchor: anchor, text: "请核实")
    let edited = "新增的前言\n\(original)"

    let resolved = try #require(
        TextAnnotationAnchorResolver.resolve(annotation, in: edited)
    )
    #expect((edited as NSString).substring(with: resolved.range) == "需要批注的结论")
    #expect(resolved.range.location > range.location)
}

@Test func textAnnotationsPersistOutsideTheMarkdownDocument() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = AnnotationPersistenceService(directoryOverride: root)
    let annotation = TextAnnotation(
        anchor: TextAnnotationAnchor(
            selectedText: "原文",
            utf16Location: 3,
            prefix: "前文",
            suffix: "后文"
        ),
        text: "这是一条批注"
    )
    let value = ["/tmp/note.md": [annotation]]

    try persistence.saveSynchronously(value)

    #expect(persistence.load() == value)
}

@Test func textAnnotationReanchorsWhenItsQuotedTextIsEdited() throws {
    let original = "开头\n需要批注的结论\n结尾"
    let selectedRange = (original as NSString).range(of: "需要批注的结论")
    let selection = EditorTextSelection(
        documentID: "/tmp/note.md",
        range: selectedRange,
        text: "需要批注的结论"
    )
    let anchor = try #require(
        TextAnnotationAnchorResolver.makeAnchor(selection: selection, in: original)
    )
    let annotation = TextAnnotation(anchor: anchor, text: "确认措辞")
    let edited = original.replacingOccurrences(of: "结论", with: "判断")
    let mutation = EditorTextMutation(
        range: (original as NSString).range(of: "结论"),
        replacementText: "判断"
    )

    let updated = TextAnnotationAnchorResolver.reanchor(
        annotation,
        from: original,
        to: edited,
        mutation: mutation
    )
    let resolved = try #require(
        TextAnnotationAnchorResolver.resolve(updated, in: edited)
    )

    #expect(updated.anchor.selectedText == "需要批注的判断")
    #expect((edited as NSString).substring(with: resolved.range) == "需要批注的判断")
}

@Test func deletedAnnotationQuoteRemainsAvailableAsAnOrphan() throws {
    let original = "开头\n需要保留的批注原文\n结尾"
    let selectedRange = (original as NSString).range(of: "需要保留的批注原文")
    let anchor = try #require(TextAnnotationAnchorResolver.makeAnchor(
        selection: EditorTextSelection(
            documentID: "/tmp/note.md",
            range: selectedRange,
            text: "需要保留的批注原文"
        ),
        in: original
    ))
    let annotation = TextAnnotation(anchor: anchor, text: "这条批注不能消失")
    let edited = (original as NSString).replacingCharacters(
        in: selectedRange,
        with: ""
    )

    let updated = TextAnnotationAnchorResolver.reanchor(
        annotation,
        from: original,
        to: edited,
        mutation: EditorTextMutation(range: selectedRange, replacementText: "")
    )

    #expect(updated.text == annotation.text)
    #expect(TextAnnotationAnchorResolver.resolve(updated, in: edited) == nil)
}

@Test func portableAnnotationsFollowTheLibraryToAnotherPath() throws {
    let parent = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let originalRoot = parent.appending(path: "原知识库", directoryHint: .isDirectory)
    let movedRoot = parent.appending(path: "新知识库", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: originalRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }

    let note = originalRoot.appending(path: "稿子/文稿.md")
    try FileManager.default.createDirectory(
        at: note.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "正文".write(to: note, atomically: true, encoding: .utf8)
    let annotation = TextAnnotation(
        anchor: TextAnnotationAnchor(
            selectedText: "正文",
            utf16Location: 0,
            prefix: "",
            suffix: ""
        ),
        text: "外部工具必须看到"
    )
    let persistence = AnnotationPersistenceService(directoryOverride: parent)
    try persistence.saveSynchronously(
        [note.standardizedFileURL.path: [annotation]],
        libraryRoot: originalRoot
    )

    let indexURL = originalRoot.appending(
        path: AnnotationPersistenceService.portableFilename
    )
    let indexText = try String(contentsOf: indexURL, encoding: .utf8)
    #expect(indexText.contains("给外部工具"))
    #expect(indexText.contains("稿子/文稿.md"))
    #expect(indexText.contains("外部工具必须看到"))
    #expect(indexText.contains("**状态**：待处理"))

    try FileManager.default.moveItem(at: originalRoot, to: movedRoot)
    let loaded = try persistence.loadLibrary(at: movedRoot)
    let movedNotePath = movedRoot.appending(path: "稿子/文稿.md")
        .standardizedFileURL.path
    #expect(loaded[movedNotePath] == [annotation])
}

@Test func annotationIndexDoesNotAppearAsANote() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "正文".write(
        to: root.appending(path: "正文.md"),
        atomically: true,
        encoding: .utf8
    )
    try "批注索引".write(
        to: root.appending(path: AnnotationPersistenceService.portableFilename),
        atomically: true,
        encoding: .utf8
    )

    let scanned = try KnowledgeBaseService().scanLibrary(
        root: root,
        excludedFolders: []
    )

    #expect(scanned.documents.map(\.url.lastPathComponent) == ["正文.md"])
}

@MainActor
@Test func annotationShortcutLetsTheEditorReadTheLiveSelection() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "快捷键.md")
    try "选中这段文字".write(to: url, atomically: true, encoding: .utf8)
    let defaultsName = "ZhijingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let store = AppStore(defaults: defaults)
    let document = NoteDocument(
        url: url,
        relativePath: url.lastPathComponent,
        modifiedAt: .now,
        size: 0
    )
    store.select(document)
    let selectedText = "选中这段文字"
    store.editorSelectionDidChange(EditorTextSelection(
        documentID: document.id,
        range: NSRange(location: 0, length: (selectedText as NSString).length),
        text: selectedText
    ))

    store.requestAnnotationComposer()

    #expect(store.inlineAnnotationRequestID == 1)
    #expect(store.errorMessage == nil)
}

@MainActor
@Test func inlineAnnotationIsInsertedIntoTheMarkdownDocument() {
    let textView = MarkdownEditorTextView()
    textView.annotationDocumentID = "文章.md"
    textView.string = "前文，需要批注的结论，后文。"
    let range = (textView.string as NSString).range(of: "需要批注的结论")
    textView.setSelectedRange(range)

    let inserted = textView.insertInlineAnnotation("这里需要补充证据", for: range)

    #expect(inserted)
    #expect(textView.string.contains("> 批注"))
    #expect(textView.string.contains("原文 · 「需要批注的结论」"))
    #expect(textView.string.contains("> 这里需要补充证据"))
}

@MainActor
@Test func annotationComposerPlaceholderDisappearsAsSoonAsTextExists() {
    let textView = AnnotationComposerTextView()
    textView.placeholder = "写下批注…"

    #expect(textView.shouldDrawPlaceholder)
    textView.string = "正在输入"
    #expect(!textView.shouldDrawPlaceholder)
}

@Test func legacyInlineAnnotationHeadingRemainsReadable() {
    #expect(InlineAnnotationMarkdown.isHeading("> 批注"))
    #expect(InlineAnnotationMarkdown.isHeading("> **批注**"))
}

@Test func inlineAnnotationStaysBesideTheSelectedParagraph() throws {
    let source = "第一段\n第二段\n第三段"
    let selection = (source as NSString).range(of: "第二段")
    let insertion = try #require(InlineAnnotationMarkdown.insertion(
        in: source,
        selection: selection,
        annotation: "请核对这个判断"
    ))
    let result = (source as NSString).replacingCharacters(
        in: insertion.range,
        with: insertion.replacementText
    )

    #expect(result.contains("第二段\n\n> 批注"))
    #expect(result.contains("> 原文 · 「第二段」"))
    #expect(result.contains("> 请核对这个判断\n\n第三段"))
}

@MainActor
@Test func editorKeepsLongFormTextLeftAlignedAtEveryWindowWidth() {
    let textView = MarkdownEditorTextView(
        frame: NSRect(x: 0, y: 0, width: 1_200, height: 700)
    )
    textView.textContainerInset = NSSize(width: 22, height: 24)
    textView.layout()
    #expect(textView.textContainerInset.width == 22)

    textView.frame.size.width = 600
    textView.layout()
    #expect(textView.textContainerInset.width == 22)
}

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

@Test func lineDiffResolvesOneHunkImmediatelyAndKeepsTheOthersPending() throws {
    let diff = LineDiff(
        original: "开头\n旧一\n中间一\n旧二\n中间二\n旧三\n中间三\n旧四\n结尾",
        replacement: "开头\n新一\n中间一\n新二\n中间二\n新三\n中间三\n新四\n结尾"
    )
    #expect(diff.hunks.count == 4)

    let acceptedSecond = try #require(diff.resolving(
        hunkID: diff.hunks[1].id,
        accepted: true
    ))
    #expect(
        acceptedSecond.settledText
            == "开头\n旧一\n中间一\n新二\n中间二\n旧三\n中间三\n旧四\n结尾"
    )

    let remainingText = try #require(acceptedSecond.remainingReplacement)
    let remainingDiff = LineDiff(
        original: acceptedSecond.settledText,
        replacement: remainingText
    )
    #expect(remainingDiff.hunks.count == 3)

    let rejectedFirst = try #require(remainingDiff.resolving(
        hunkID: remainingDiff.hunks[0].id,
        accepted: false
    ))
    #expect(rejectedFirst.settledText == acceptedSecond.settledText)
    #expect(
        rejectedFirst.remainingReplacement
            == "开头\n旧一\n中间一\n新二\n中间二\n新三\n中间三\n新四\n结尾"
    )
}

@Test func lineDiffFinishesAsSoonAsItsLastHunkIsResolved() throws {
    let diff = LineDiff(original: "开头\n旧内容\n结尾", replacement: "开头\n新内容\n结尾")

    let accepted = try #require(diff.resolving(hunkID: 0, accepted: true))
    #expect(accepted.settledText == "开头\n新内容\n结尾")
    #expect(accepted.remainingReplacement == nil)
    #expect(accepted.settledLine == 2)

    let rejected = try #require(diff.resolving(hunkID: 0, accepted: false))
    #expect(rejected.settledText == "开头\n旧内容\n结尾")
    #expect(rejected.remainingReplacement == nil)
}

@Test func inlineDiffPresentationKeepsContextAndPlacesChangesInDocumentOrder() throws {
    let presentation = InlineDiffPresentation(diff: LineDiff(
        original: "开头\n旧段落\n结尾",
        replacement: "开头\n新段落\n结尾"
    ))

    #expect(presentation.text == "开头\n旧段落\n新段落\n \n结尾")
    #expect(presentation.decorations.count == 2)
    #expect(presentation.decorations.map(\.kind) == [.removed, .inserted])
    #expect(presentation.decorations.map(\.hunkID) == [0, 0])
    #expect(presentation.controlAnchors.map(\.hunkID) == [0])
    let source = presentation.text as NSString
    #expect(source.substring(with: presentation.decorations[0].range) == "旧段落")
    #expect(source.substring(with: presentation.decorations[1].range) == "新段落")
}

@Test func inlineDiffPresentationPreservesUnchangedDocumentWithoutDecorations() {
    let presentation = InlineDiffPresentation(diff: LineDiff(
        original: "第一行\n\n最后一行\n",
        replacement: "第一行\n\n最后一行\n"
    ))

    #expect(presentation.text == "第一行\n\n最后一行\n")
    #expect(presentation.decorations.isEmpty)
    #expect(presentation.controlAnchors.isEmpty)
    #expect(presentation.firstChangeRange == nil)
}

@Test func inlineDiffPresentationProvidesOneDecisionControlPerHunk() {
    let presentation = InlineDiffPresentation(diff: LineDiff(
        original: "开头\n旧段一\n中间\n旧段二\n结尾",
        replacement: "开头\n新段一\n中间\n新段二\n结尾"
    ))

    #expect(presentation.controlAnchors.map(\.hunkID) == [0, 1])
    #expect(Set(presentation.decorations.map(\.hunkID)) == [0, 1])
}

@MainActor
@Test func inlineDiffDecisionControlCanBeCreated() {
    let control = InlineDiffDecisionControl(hunkID: 7)

    #expect(control.hunkID == 7)
    #expect(control.intrinsicContentSize.width > 0)
    #expect(control.intrinsicContentSize.height > 0)
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

@Test func libraryWatcherSerializesRepeatedStartAndStop() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let watcher = LibraryWatcher()

    for _ in 0..<100 {
        watcher.start(root: root, excludedFolders: []) { _ in }
        watcher.stop()
    }
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
    let migrated = DocumentStateStore.migrateLegacyKeys(
        favorites: ["共享.md"],
        documents: [first]
    )

    #expect(first.persistenceKey != second.persistenceKey)
    #expect(migrated.favorites == [first.persistenceKey])

    let afterSwitch = DocumentStateStore.migrateLegacyKeys(
        favorites: migrated.favorites,
        documents: [second]
    )
    #expect(!afterSwitch.didChange)
    #expect(afterSwitch.favorites == [first.persistenceKey])
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
        original: "开始审阅时的正文",
        replacement: "外部修改后的正文"
    )

    #expect(proposal.canApply(to: "文章.md", currentText: "开始审阅时的正文"))
    #expect(!proposal.canApply(to: "文章.md", currentText: "用户后来输入的新正文"))
    #expect(!proposal.canApply(to: "另一篇.md", currentText: "开始审阅时的正文"))
}

@Test func externalEditProposalUsesTheReviewingSaveState() {
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
@Test func editorRemovalClearsUndoActionsTargetingTheOldTextView() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    let textView = MarkdownEditorTextView(frame: window.contentView?.bounds ?? .zero)
    window.contentView = textView
    window.makeFirstResponder(textView)
    textView.allowsUndo = true

    guard let undoManager = textView.undoManager else {
        Issue.record("编辑器未创建撤销管理器")
        return
    }
    undoManager.registerUndo(withTarget: textView) { _ in }
    #expect(undoManager.canUndo)

    textView.discardUndoHistory()

    #expect(!undoManager.canUndo)
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

@Test func markdownLinkDetectionOnlyScansTheRequestedViewport() {
    let source = """
    [第一个](https://first.example)
    中间正文
    [可见链接](https://visible.example)
    """
    let visibleRange = (source as NSString).range(of: "[可见链接]")
    let links = MarkdownLinkDetector.links(
        in: source,
        characterRange: (source as NSString).lineRange(for: visibleRange)
    )

    #expect(links.count == 1)
    #expect(links.first?.url.absoluteString == "https://visible.example")
    #expect(links.first?.range.location == visibleRange.location)
}

@Test func markdownFenceStateCanBeResolvedOffTheMainThread() async {
    let source = "前文\n```swift\n" + String(repeating: "let value = 1\n", count: 5_000)
    let location = source.utf16.count
    let isInside = await Task.detached {
        MarkdownFenceStateResolver.isInsideFence(before: location, in: source)
    }.value

    #expect(isInside)
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

@MainActor
@Test func lineNumbersFollowActualFragmentsWithoutNumberingWrappedRows() {
    let source = "第一行很长，需要在狭窄编辑器里自动换成好几排文字来验证位置\n\n第三行"
    let scrollView = NSScrollView(
        frame: NSRect(x: 0, y: 0, width: 190, height: 240)
    )
    let textView = MarkdownEditorTextView(frame: scrollView.contentView.bounds)
    textView.textContainerInset = NSSize(width: 22, height: 24)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.containerSize = NSSize(
        width: scrollView.contentSize.width,
        height: CGFloat.greatestFiniteMagnitude
    )
    textView.textContainer?.widthTracksTextView = true
    textView.string = source
    MarkdownSourceEditor.Coordinator.applyPlainTextAppearance(to: textView)
    scrollView.documentView = textView

    guard let layoutManager = textView.layoutManager,
          let textContainer = textView.textContainer else {
        Issue.record("无法建立行号布局测试")
        return
    }
    layoutManager.ensureLayout(for: textContainer)
    let ruler = MarkdownLineNumberRulerView(textView: textView)
    let markers = ruler.lineNumberMarkers(in: textView.bounds)

    #expect(markers.map(\.lineNumber) == [1, 2, 3])
    #expect(markers[1].rectInTextView.minY > markers[0].rectInTextView.minY)
    #expect(markers[2].rectInTextView.minY > markers[1].rectInTextView.minY)
    #expect(markers[0].rectInTextView.minY == textView.textContainerOrigin.y)
}

@Test func readingModeRemovesMarkdownSourceMarkers() {
    let source = """
    # **标题**

    > 一段引用

    - 列表项目

    [链接文字](https://example.com)
    """
    let visibleText = MarkdownReadingAttributedRenderer.render(source).string

    #expect(visibleText.contains("标题"))
    #expect(visibleText.contains("一段引用"))
    #expect(visibleText.contains("列表项目"))
    #expect(visibleText.contains("链接文字"))
    #expect(!visibleText.contains("#"))
    #expect(!visibleText.contains("**"))
    #expect(!visibleText.contains(">"))
    #expect(!visibleText.contains("https://"))
}

@Test func inlineTextMarksUseReadableMarkdownAndCanBeReplacedOrCleared() throws {
    let source = "这是重点内容"
    let selection = (source as NSString).range(of: "重点")
    let highlighted = try #require(InlineTextMarkMarkdown.mutation(
        in: source,
        selection: selection,
        applying: .highlight
    ))

    #expect(highlighted.replacementText == "[重点]{.mark}")
    #expect(highlighted.selectionRange == NSRange(location: 3, length: 2))

    let highlightedSource = (source as NSString).replacingCharacters(
        in: highlighted.range,
        with: highlighted.replacementText
    )
    let important = try #require(InlineTextMarkMarkdown.mutation(
        in: highlightedSource,
        selection: highlighted.selectionRange,
        applying: .important
    ))
    #expect(important.replacementText == "[重点]{.important}")

    let importantSource = (highlightedSource as NSString).replacingCharacters(
        in: important.range,
        with: important.replacementText
    )
    let cleared = try #require(InlineTextMarkMarkdown.mutation(
        in: importantSource,
        selection: important.selectionRange,
        applying: .important
    ))
    #expect(cleared.replacementText == "重点")
    #expect(cleared.selectionRange == selection)
}

@Test func inlineTextMarksRecognizeAllFourSemanticStylesAndOffsets() {
    let source = "前缀 [荧光]{.mark} [警示]{.important} [概念]{.concept} [句子]{.underline}"
    let spans = InlineTextMarkMarkdown.spans(in: source, baseLocation: 12)

    #expect(spans.map(\.kind) == [
        .highlight,
        .important,
        .concept,
        .underline,
    ])
    #expect(spans.first?.fullRange.location == 15)
    #expect(spans.first?.contentRange.location == 16)
}

@Test func inlineTextMarksDoNotWrapMultipleLinesOrMarkdownLinks() {
    let multiline = "第一行\n第二行"
    #expect(InlineTextMarkMarkdown.mutation(
        in: multiline,
        selection: NSRange(location: 0, length: multiline.utf16.count),
        applying: .underline
    ) == nil)

    let link = "[链接](https://example.com)"
    let linkText = (link as NSString).range(of: "链接")
    #expect(InlineTextMarkMarkdown.mutation(
        in: link,
        selection: linkText,
        applying: .concept
    ) == nil)
}

@MainActor
@Test func editorPresentsTextMarksWithoutChangingTextMetrics() throws {
    let source = "[荧光]{.mark} [警示]{.important} [概念]{.concept} [句子]{.underline}"
    let textView = MarkdownEditorTextView()
    textView.isRichText = false
    textView.string = source
    MarkdownSourceEditor.Coordinator.applyPlainTextAppearance(to: textView)
    MarkdownPresentationHighlighter.apply(to: textView)
    let spans = InlineTextMarkMarkdown.spans(in: source)
    let layoutManager = try #require(textView.layoutManager)

    let highlightAttributes = layoutManager.temporaryAttributes(
        atCharacterIndex: spans[0].contentRange.location,
        effectiveRange: nil
    )
    #expect(highlightAttributes[.backgroundColor] != nil)
    #expect(highlightAttributes[.font] == nil)

    let importantAttributes = layoutManager.temporaryAttributes(
        atCharacterIndex: spans[1].contentRange.location,
        effectiveRange: nil
    )
    #expect(importantAttributes[.foregroundColor] != nil)
    #expect(importantAttributes[.font] == nil)

    let underlineAttributes = layoutManager.temporaryAttributes(
        atCharacterIndex: spans[3].contentRange.location,
        effectiveRange: nil
    )
    #expect(underlineAttributes[.underlineStyle] != nil)
    #expect(underlineAttributes[.underlineColor] != nil)
}

@MainActor
@Test func editorCollapsesInactiveTextMarkSyntaxAndRevealsTheActiveMark() throws {
    let source = "前文 [重点结论]{.important} 后文"
    let span = try #require(InlineTextMarkMarkdown.spans(in: source).first)
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

    textView.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
    textView.updateSelectionAnnotationButton()
    let layoutManager = try #require(textView.layoutManager)
    let textContainer = try #require(textView.textContainer)
    layoutManager.ensureLayout(for: textContainer)
    let hiddenGlyphIndex = layoutManager.glyphIndexForCharacter(
        at: span.prefixRange.location
    )
    #expect(layoutManager.propertyForGlyph(at: hiddenGlyphIndex).contains(.null))

    textView.setSelectedRange(span.contentRange)
    textView.updateSelectionAnnotationButton()
    layoutManager.ensureLayout(for: textContainer)
    let revealedGlyphIndex = layoutManager.glyphIndexForCharacter(
        at: span.prefixRange.location
    )
    #expect(!layoutManager.propertyForGlyph(at: revealedGlyphIndex).contains(.null))
    #expect(textView.selectedRange() == span.contentRange)
}

@MainActor
@Test func selectionActionsAreDirectOrderedPillsWithClearAtTheRight() throws {
    let source = "前文重点后文"
    let scrollView = NSScrollView(
        frame: NSRect(x: 0, y: 0, width: 340, height: 180)
    )
    let textView = MarkdownEditorTextView(frame: scrollView.contentView.bounds)
    textView.annotationDocumentID = "测试.md"
    textView.isRichText = false
    textView.isHorizontallyResizable = false
    textView.textContainer?.containerSize = NSSize(
        width: scrollView.contentSize.width,
        height: CGFloat.greatestFiniteMagnitude
    )
    textView.textContainer?.widthTracksTextView = true
    MarkdownSourceEditor.Coordinator.applyPlainTextAppearance(to: textView)
    textView.string = source
    scrollView.documentView = textView
    textView.setSelectedRange((source as NSString).range(of: "重点"))
    textView.updateSelectionAnnotationButton()
    textView.layoutSubtreeIfNeeded()

    let orderedButtons = textView.subviews.compactMap { $0 as? NSButton }
        .filter { !$0.isHidden }
        .sorted { $0.frame.minX < $1.frame.minX }
    #expect(orderedButtons.map(\.title) == [
        "荧光", "重要", "概念", "下划线", "批注", "清除"
    ])

    let conceptButton = try #require(
        orderedButtons.compactMap { $0 as? SelectionMarkButton }
            .first { $0.kind == .concept }
    )
    let clearButton = try #require(
        orderedButtons.compactMap { $0 as? SelectionMarkButton }
            .first { $0.isClearAction }
    )
    #expect(!clearButton.isEnabled)
    #expect(clearButton.alphaValue == 1)
    #expect(clearButton.frame.maxX <= textView.visibleRect.maxX - 8)

    conceptButton.performClick(nil)
    #expect(textView.string.contains("[重点]{.concept}"))
    #expect(clearButton.isEnabled)

    clearButton.performClick(nil)
    #expect(textView.string == source)
}

@Test func readingModeHidesTextMarkSyntaxAndKeepsVisualStyles() throws {
    let source = "[荧光]{.mark} [警示]{.important} [概念]{.concept} [句子]{.underline}"
    let rendered = MarkdownReadingAttributedRenderer.render(source)

    #expect(rendered.string.contains("荧光 警示 概念 句子"))
    #expect(!rendered.string.contains("{.mark}"))
    let nsText = rendered.string as NSString
    let highlightRange = nsText.range(of: "荧光")
    let importantRange = nsText.range(of: "警示")
    let conceptRange = nsText.range(of: "概念")
    let underlineRange = nsText.range(of: "句子")
    #expect(rendered.attribute(
        .backgroundColor,
        at: highlightRange.location,
        effectiveRange: nil
    ) != nil)
    #expect(rendered.attribute(
        .foregroundColor,
        at: importantRange.location,
        effectiveRange: nil
    ) != nil)
    #expect(rendered.attribute(
        .foregroundColor,
        at: conceptRange.location,
        effectiveRange: nil
    ) != nil)
    #expect(rendered.attribute(
        .underlineStyle,
        at: underlineRange.location,
        effectiveRange: nil
    ) != nil)
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
            loadedText: "更早的基线",
            editorText: "当前编辑内容",
            diskText: "刚刚由应用写入的旧内容",
            knownLocalWriteSignatures: [
                DocumentContentSignature("刚刚由应用写入的旧内容")
            ]
        ) == .localWriteObserved("刚刚由应用写入的旧内容")
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

    let marked = DocumentMetrics(
        markdown: "[荧光]{.mark} [警示]{.important} [概念]{.concept} [句子]{.underline}"
    )
    #expect(marked.count == 8)

    let long = DocumentMetrics(markdown: String(repeating: "知", count: 501))
    #expect(long.count == 501)
    #expect(long.speakingDurationLabel == "约 2 分钟")

    let brief = DocumentMetrics(markdown: "这是一段很短的口播")
    #expect(brief.speakingDurationLabel == "不足 1 分钟")
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

    [荧光]{.mark} [警示]{.important} [概念]{.concept} [句子]{.underline}

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
    let pdfDocument = try #require(PDFDocument(url: pdfURL))
    #expect(pdfDocument.pageCount >= 2)
    let extractedPDFText = pdfDocument.string?
        .precomposedStringWithCompatibilityMapping ?? ""
    for markedText in ["荧光", "警示", "概念", "句子"] {
        #expect(extractedPDFText.contains(markedText))
    }
    #expect(!extractedPDFText.contains("{.mark}"))
    #expect((try Data(contentsOf: wordURL)).starts(with: Data([0x50, 0x4B])))
    #expect((try wordURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 1_000)
}
