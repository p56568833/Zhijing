import Foundation
import Testing
@testable import Zhijing

@MainActor
@Test func openingLoadedMarkdownSelectsItBeforeReturning() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "ZhijingDocumentOpening-\(UUID().uuidString)", directoryHint: .isDirectory)
    let support = root.appending(path: "Support", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let restoredURL = root.appending(path: "上次打开.md")
    let requestedURL = root.appending(path: "这次点击.md")
    try "# 上次打开".write(to: restoredURL, atomically: true, encoding: .utf8)
    try "# 这次点击".write(to: requestedURL, atomically: true, encoding: .utf8)

    let suiteName = "ZhijingDocumentOpeningTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = AppStore(
        defaults: defaults,
        knowledgeBase: KnowledgeBaseService(supportDirectoryOverride: support)
    )
    store.libraryURL = root
    await store.refreshLibrary(selecting: "上次打开.md")
    #expect(store.selectedDocument?.url.lastPathComponent == restoredURL.lastPathComponent)

    store.openDocuments(at: [requestedURL])

    #expect(store.selectedDocument?.url.lastPathComponent == requestedURL.lastPathComponent)
    #expect(store.editorText == "# 这次点击")
}
