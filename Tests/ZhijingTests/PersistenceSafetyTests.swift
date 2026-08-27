import Foundation
import Testing
@testable import Zhijing

@Test func corruptPortableAnnotationStoreIsPreserved() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appending(
        path: AnnotationPersistenceService.portableFilename
    )
    let original = "# 无法解析但必须保留\n".data(using: .utf8)!
    try original.write(to: url)
    let service = AnnotationPersistenceService(
        directoryOverride: directory.appending(path: "Support")
    )

    #expect(throws: (any Error).self) {
        try service.saveSynchronously([:], libraryRoot: directory)
    }
    #expect(try Data(contentsOf: url) == original)
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "ZhijingPersistenceTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    return url
}

@Test func unchangedPersistenceSnapshotsDoNotRewriteFiles() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let library = directory.appending(path: "Library")
    try FileManager.default.createDirectory(
        at: library,
        withIntermediateDirectories: true
    )
    let documentURL = library.appending(path: "note.md")
    let annotation = TextAnnotation(
        anchor: TextAnnotationAnchor(
            selectedText: "正文",
            utf16Location: 0,
            prefix: "",
            suffix: ""
        ),
        text: "批注"
    )
    let annotations = [documentURL.path: [annotation]]
    let annotationService = AnnotationPersistenceService(
        directoryOverride: directory.appending(path: "Support")
    )
    try annotationService.saveSynchronously(
        annotations,
        libraryRoot: library
    )
    let portableURL = library.appending(
        path: AnnotationPersistenceService.portableFilename
    )
    try setOldModificationDate(for: portableURL)
    try annotationService.saveSynchronously(
        annotations,
        libraryRoot: library
    )
    #expect(try modificationDate(for: portableURL) == oldModificationDate)
}

@Test func emptyAnnotationsDoNotCreateAStandaloneIndex() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let service = AnnotationPersistenceService(
        directoryOverride: directory.appending(path: "Support")
    )
    try service.saveSynchronously([:], libraryRoot: directory)

    let portableURL = directory.appending(
        path: AnnotationPersistenceService.portableFilename
    )
    #expect(!FileManager.default.fileExists(atPath: portableURL.path))
}

@Test func emptyExternalAnnotationSidecarIsDifferentFromAMissingSidecar() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let documentURL = directory.appending(path: "note.md")
    try "正文".write(to: documentURL, atomically: true, encoding: .utf8)
    let document = NoteDocument(
        url: documentURL,
        relativePath: "note.md",
        modifiedAt: .now,
        size: 6
    )
    let service = AnnotationPersistenceService(
        directoryOverride: directory.appending(path: "Support")
    )

    #expect(try service.loadExternal(document: document) == nil)

    let annotation = TextAnnotation(
        anchor: TextAnnotationAnchor(
            selectedText: "正文",
            utf16Location: 0,
            prefix: "",
            suffix: ""
        ),
        text: "临时批注"
    )
    try service.saveSynchronously(
        [document.persistenceKey: [annotation]],
        externalDocuments: [document]
    )
    #expect(try service.loadExternal(document: document) == [annotation])

    try service.saveSynchronously([:], externalDocuments: [document])
    #expect(try service.loadExternal(document: document) == [])
}

@Test func libraryWatcherIgnoresInternalAnnotationFiles() {
    let root = URL(filePath: "/tmp/zhijing-library", directoryHint: .isDirectory)
    let portable = root.appending(
        path: AnnotationPersistenceService.portableFilename
    )
    let sidecar = root.appending(path: "note.md.zhijing-comments.md")
    let document = root.appending(path: "note.md")

    #expect(!LibraryWatcher.shouldInclude(
        portable,
        rootPath: root.path,
        excludedFolders: []
    ))
    #expect(!LibraryWatcher.shouldInclude(
        sidecar,
        rootPath: root.path,
        excludedFolders: []
    ))
    #expect(LibraryWatcher.shouldInclude(
        document,
        rootPath: root.path,
        excludedFolders: []
    ))
}

private let oldModificationDate = Date(timeIntervalSince1970: 1_000)

private func setOldModificationDate(for url: URL) throws {
    try FileManager.default.setAttributes(
        [.modificationDate: oldModificationDate],
        ofItemAtPath: url.path
    )
}

private func modificationDate(for url: URL) throws -> Date {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.modificationDate] as? Date)
}
