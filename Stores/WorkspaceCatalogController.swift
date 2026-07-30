import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceCatalogController {
    var libraryURL: URL?
    var documents: [NoteDocument] = []
    var folders: [String] = []
    private(set) var libraryTree: [LibraryTreeItem] = []
    private(set) var recentDocuments: [NoteDocument] = []
    private(set) var favoriteDocuments: [NoteDocument] = []
    var isIndexing = false

    @ObservationIgnored
    private var documentByPath: [String: NoteDocument] = [:]
    @ObservationIgnored
    private var refreshID = UUID()
    private let service: KnowledgeBaseService

    init(service: KnowledgeBaseService) {
        self.service = service
    }

    @discardableResult
    func refresh(
        excludedFolders: [String],
        favorites: Set<String>
    ) async throws -> LibraryScanResult? {
        guard let root = libraryURL else { return nil }
        let id = UUID()
        refreshID = id
        isIndexing = true
        defer {
            if refreshID == id {
                isIndexing = false
            }
        }
        let service = service
        let scanned: LibraryScanResult
        do {
            scanned = try await Task.detached {
                try service.scanLibrary(
                    root: root,
                    excludedFolders: excludedFolders
                )
            }.value
        } catch {
            guard refreshID == id else { return nil }
            throw error
        }
        guard refreshID == id,
              libraryURL?.standardizedFileURL == root.standardizedFileURL
        else { return nil }
        documents = scanned.documents
        folders = scanned.folders
        rebuildDerivedState(favorites: favorites)
        return scanned
    }

    func transition(to url: URL) {
        refreshID = UUID()
        libraryURL = url.standardizedFileURL
        documents = []
        folders = []
        documentByPath = [:]
        libraryTree = []
        recentDocuments = []
        favoriteDocuments = []
        isIndexing = false
    }

    func cancelRefresh() {
        refreshID = UUID()
        isIndexing = false
    }

    func rebuildDerivedState(favorites: Set<String>) {
        documentByPath = Dictionary(
            uniqueKeysWithValues: documents.map { ($0.relativePath, $0) }
        )
        recentDocuments = Array(
            documents.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(8)
        )
        favoriteDocuments = documents.filter {
            favorites.contains($0.persistenceKey)
        }
        libraryTree = LibraryTreeBuilder.build(
            folders: folders,
            documents: documents
        )
    }

    func document(at relativePath: String) -> NoteDocument? {
        documentByPath[relativePath]
    }

    func isLibraryDocument(_ document: NoteDocument) -> Bool {
        documentByPath[document.relativePath]?.id == document.id
    }

    func updateDocumentMetadata(
        _ refreshed: NoteDocument,
        favorites: Set<String>
    ) {
        guard let index = documents.firstIndex(where: {
            $0.id == refreshed.id
        }) else { return }
        documents[index] = refreshed
        rebuildDerivedState(favorites: favorites)
    }
}
