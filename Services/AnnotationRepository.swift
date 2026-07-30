import Foundation

struct AnnotationResolutionSnapshot: Equatable, Sendable {
    let resolved: [ResolvedTextAnnotation]
    let displayItems: [TextAnnotationDisplayItem]

    static let empty = AnnotationResolutionSnapshot(
        resolved: [],
        displayItems: []
    )
}

struct AnnotationResolutionCache {
    private var documentKey: String?
    private var annotations: [TextAnnotation] = []
    private var text = ""
    private var snapshot: AnnotationResolutionSnapshot?

    private(set) var cacheMissCount = 0

    mutating func resolve(
        documentKey: String?,
        annotations: [TextAnnotation],
        text: String
    ) -> AnnotationResolutionSnapshot {
        if let snapshot,
           self.documentKey == documentKey,
           self.annotations == annotations,
           self.text == text {
            return snapshot
        }

        let snapshot = Self.makeSnapshot(
            annotations: annotations,
            text: text
        )
        self.documentKey = documentKey
        self.annotations = annotations
        self.text = text
        self.snapshot = snapshot
        cacheMissCount &+= 1
        return snapshot
    }

    mutating func reset() {
        documentKey = nil
        annotations = []
        text = ""
        snapshot = nil
    }

    private static func makeSnapshot(
        annotations: [TextAnnotation],
        text: String
    ) -> AnnotationResolutionSnapshot {
        guard !annotations.isEmpty else { return .empty }

        var resolved: [ResolvedTextAnnotation] = []
        var displayItems: [TextAnnotationDisplayItem] = []
        resolved.reserveCapacity(annotations.count)
        displayItems.reserveCapacity(annotations.count)

        for annotation in annotations {
            let item = TextAnnotationAnchorResolver.resolve(annotation, in: text)
            if let item {
                resolved.append(item)
            }
            displayItems.append(
                TextAnnotationDisplayItem(
                    annotation: annotation,
                    range: item?.range
                )
            )
        }
        displayItems.sort { lhs, rhs in
            switch (lhs.range, rhs.range) {
            case let (.some(left), .some(right)):
                return left.location < right.location
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.annotation.createdAt < rhs.annotation.createdAt
            }
        }
        return AnnotationResolutionSnapshot(
            resolved: resolved,
            displayItems: displayItems
        )
    }
}

@MainActor
final class AnnotationRepository {
    private let persistence: AnnotationPersistenceService
    private var loadedLibraryRootPath: String?
    private var blockedLibraryRootPaths: Set<String> = []
    private var resolutionCache = AnnotationResolutionCache()

    init(persistence: AnnotationPersistenceService = .init()) {
        self.persistence = persistence
    }

    func loadCachedAnnotations() throws -> [String: [TextAnnotation]] {
        try persistence.loadStrict()
    }

    func resolution(
        documentKey: String?,
        annotations: [TextAnnotation],
        text: String
    ) -> AnnotationResolutionSnapshot {
        resolutionCache.resolve(
            documentKey: documentKey,
            annotations: annotations,
            text: text
        )
    }

    func reanchor(
        _ annotations: [TextAnnotation],
        from oldText: String,
        to newText: String,
        mutation: EditorTextMutation?
    ) -> [TextAnnotation] {
        annotations.map {
            TextAnnotationAnchorResolver.reanchor(
                $0,
                from: oldText,
                to: newText,
                mutation: mutation
            )
        }
    }

    func loadLibraryIfNeeded(
        at root: URL,
        into annotations: inout [String: [TextAnnotation]]
    ) throws {
        let rootPath = root.standardizedFileURL.path
        guard loadedLibraryRootPath != rootPath else { return }
        let portableURL = root.appending(
            path: AnnotationPersistenceService.portableFilename
        )
        let hasPortableFile = FileManager.default.fileExists(
            atPath: portableURL.path
        )

        do {
            let portable = try persistence.loadLibrary(at: root)
            let prefix = rootPath + "/"
            if hasPortableFile {
                annotations = annotations.filter { !$0.key.hasPrefix(prefix) }
                annotations.merge(portable) { _, portableValue in portableValue }
            } else {
                let hasLegacyValues = annotations.contains {
                    $0.key.hasPrefix(prefix) && !$0.value.isEmpty
                }
                if hasLegacyValues {
                    persistence.saveLibrary(annotations, at: root)
                }
            }
            loadedLibraryRootPath = rootPath
            blockedLibraryRootPaths.remove(rootPath)
        } catch {
            blockedLibraryRootPaths.insert(rootPath)
            throw error
        }
    }

    func loadExternalAnnotations(
        for document: NoteDocument
    ) throws -> [TextAnnotation]? {
        try persistence.loadExternal(document: document)
    }

    func save(
        _ annotations: [String: [TextAnnotation]],
        libraryRoot: URL?,
        externalDocument: NoteDocument?
    ) {
        persistence.save(annotations)
        if let libraryRoot {
            let rootPath = libraryRoot.standardizedFileURL.path
            if !blockedLibraryRootPaths.contains(rootPath) {
                persistence.saveLibrary(annotations, at: libraryRoot)
            }
        }
        if let externalDocument {
            persistence.saveExternal(
                annotations[externalDocument.persistenceKey] ?? [],
                document: externalDocument
            )
        }
    }

    func saveSynchronously(
        _ annotations: [String: [TextAnnotation]],
        libraryRoot: URL?,
        externalDocuments: [NoteDocument]
    ) throws {
        try persistence.saveSynchronously(
            annotations,
            libraryRoot: libraryRoot,
            externalDocuments: externalDocuments
        )
    }

    func transitionToLibrary() {
        loadedLibraryRootPath = nil
        resolutionCache.reset()
    }
}
