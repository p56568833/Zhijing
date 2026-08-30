import Foundation
import Testing
@testable import Zhijing

// MARK: - LineDiff 行尾保真

@Test func lineDiffPreservesCRLFLineEndingsWhenApplyingHunks() throws {
    let original = "第一行\r\n第二行\r\n第三行\r\n"
    let replacement = "第一行\r\n改写后的第二行\r\n第三行\r\n"
    let diff = LineDiff(original: original, replacement: replacement)

    let settled = diff.applying(acceptedHunkIDs: [])
    #expect(settled == original)

    let accepted = diff.applying(acceptedHunkIDs: Set(diff.hunks.map(\.id)))
    #expect(accepted == replacement)
    // 拒绝全部改动时不能把 CRLF 静默改写成 LF。
    #expect(!settled.contains("\n") || settled.contains("\r\n"))
}

@Test func lineDiffKeepsLFDocumentsOnLF() throws {
    let original = "a\nb\nc\n"
    let replacement = "a\nB\nc\n"
    let diff = LineDiff(original: original, replacement: replacement)
    #expect(diff.applying(acceptedHunkIDs: []) == original)
    #expect(diff.applying(acceptedHunkIDs: Set(diff.hunks.map(\.id))) == replacement)
}

// MARK: - 手动排序

@Test func manualOrderAppliesToLargePathSetsWithoutQuadraticScan() {
    let manualOrder = (0..<1000).map { "doc-\($0)" }
    let paths = Array(manualOrder.reversed()) + ["extra-1", "extra-2"]
    let ordered = DocumentOrdering.applyingManualOrder(manualOrder, to: paths)

    #expect(Array(ordered.prefix(1000)) == manualOrder)
    #expect(Array(ordered.suffix(2)) == ["extra-1", "extra-2"])
}

// MARK: - 目录派生态对重复路径的容错

@MainActor
@Test func catalogRebuildSurvivesDuplicateRelativePaths() {
    let catalog = WorkspaceCatalogController(service: KnowledgeBaseService())
    let first = NoteDocument(
        url: URL(filePath: "/tmp/lib/a.md"),
        relativePath: "a.md",
        modifiedAt: .now,
        size: 10
    )
    let second = NoteDocument(
        url: URL(filePath: "/tmp/elsewhere/a.md"),
        relativePath: "a.md",
        modifiedAt: .now,
        size: 20
    )
    catalog.documents = [first, second]
    catalog.folders = []

    catalog.rebuildDerivedState(favorites: [])

    #expect(catalog.document(at: "a.md")?.id == first.id)
}

// MARK: - 代码围栏内链接过滤

@Test func fenceScanExcludesLinksInsideCodeFences() {
    let source = """
    正文 [链接](https://example.com) 一段

    ```swift
    let s = "[代码里的链接](https://should-not-open.example)"
    ```

    结尾 [又一个](https://example.org)
    """
    let scan = MarkdownFenceStateResolver.scan(before: 0, in: source)
    let links = MarkdownLinkDetector.links(in: source)
    let allowed = links.filter { link in
        scan.fencedRanges.allSatisfy {
            NSIntersectionRange($0, link.range).length == 0
        }
    }

    #expect(links.count == 3)
    #expect(allowed.count == 2)
    #expect(allowed.contains { $0.url.absoluteString == "https://example.com" })
    #expect(allowed.contains { $0.url.absoluteString == "https://example.org" })
}

@Test func fenceScanReportsStateAtLocation() {
    let source = "```\ncode\n```\n正文"
    let nsSource = source as NSString
    let afterOpeningFence = nsSource.range(of: "code").location
    let afterClosingFence = nsSource.range(of: "正文").location

    #expect(MarkdownFenceStateResolver.scan(
        before: afterOpeningFence,
        in: source
    ).startsInsideFence == true)
    #expect(MarkdownFenceStateResolver.scan(
        before: afterClosingFence,
        in: source
    ).startsInsideFence == false)
    #expect(MarkdownFenceStateResolver.scan(
        before: 0,
        in: source
    ).startsInsideFence == false)
}

// MARK: - 批注重锚定：编辑推断只算一次

@Test func reanchorWithPrecomputedEditMatchesLegacyBehavior() throws {
    let document = "开头 [被批注的文字] 结尾，后面还有一句。"
    let nsDocument = document as NSString
    let selectionRange = nsDocument.range(of: "被批注的文字")
    let selection = EditorTextSelection(
        documentID: "doc",
        range: selectionRange,
        text: "被批注的文字"
    )
    let anchor = try #require(TextAnnotationAnchorResolver.makeAnchor(
        selection: selection,
        in: document
    ))
    let annotation = TextAnnotation(anchor: anchor, text: "批注内容")

    // 在文档末尾追加一句话的编辑：锚点原位不动。
    let newText = document + "追加的一句。"
    let edit = try #require(TextAnnotationAnchorResolver.edit(
        mutation: nil,
        from: document,
        to: newText
    ))
    let reanchored = TextAnnotationAnchorResolver.reanchor(
        annotation,
        from: document,
        to: newText,
        edit: edit
    )

    #expect(reanchored.anchor.utf16Location == annotation.anchor.utf16Location)
    #expect(reanchored.anchor.selectedText == annotation.anchor.selectedText)
}

// MARK: - 便携批注加载失败的冷却

@MainActor
@Test func annotationRepositoryCoolsDownAfterPortableLoadFailure() throws {
    let scratch = FileManager.default.temporaryDirectory
        .appending(path: "zhijing-hardening-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    let corrupt = scratch.appending(path: AnnotationPersistenceService.portableFilename)
    try Data("not a portable file".utf8).write(to: corrupt)

    let repository = AnnotationRepository(
        persistence: AnnotationPersistenceService()
    )
    var annotations: [String: [TextAnnotation]] = [:]

    #expect(throws: Error.self) {
        try repository.loadLibraryIfNeeded(at: scratch, into: &annotations)
    }
    // 冷却期内同库的重复加载（自动保存触发的刷新）应静默跳过。
    try repository.loadLibraryIfNeeded(at: scratch, into: &annotations)
}
