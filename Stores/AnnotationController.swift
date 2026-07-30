import Foundation
import Observation

@MainActor
@Observable
final class AnnotationController {
    private(set) var annotations: [String: [TextAnnotation]] = [:]
    private(set) var composerRequest: AnnotationComposerRequest?

    private let repository: AnnotationRepository
    private let knowledgeBase: KnowledgeBaseService

    init(
        repository: AnnotationRepository = .init(),
        knowledgeBase: KnowledgeBaseService = .init()
    ) {
        self.repository = repository
        self.knowledgeBase = knowledgeBase
    }

    func loadCachedAnnotations() throws {
        annotations = try repository.loadCachedAnnotations()
    }

    func discardCachedAnnotations() {
        annotations = [:]
    }

    func annotations(for document: NoteDocument?) -> [TextAnnotation] {
        guard let key = document?.persistenceKey else { return [] }
        return annotations[key] ?? []
    }

    func resolution(
        for document: NoteDocument?,
        text: String
    ) -> AnnotationResolutionSnapshot {
        repository.resolution(
            documentKey: document?.persistenceKey,
            annotations: annotations(for: document),
            text: text
        )
    }

    func beginComposing(for selection: EditorTextSelection) {
        composerRequest = AnnotationComposerRequest(selection: selection)
    }

    func cancelComposing() {
        composerRequest = nil
    }

    @discardableResult
    func add(
        text: String,
        selection: EditorTextSelection,
        document: NoteDocument,
        documentText: String
    ) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let anchor = TextAnnotationAnchorResolver.makeAnchor(
                  selection: selection,
                  in: documentText
              ) else { return false }
        annotations[document.persistenceKey, default: []].append(
            TextAnnotation(anchor: anchor, text: value)
        )
        composerRequest = nil
        return true
    }

    @discardableResult
    func update(id: UUID, text: String, document: NoteDocument?) -> Bool {
        guard let key = document?.persistenceKey,
              let index = annotations[key]?.firstIndex(where: { $0.id == id })
        else { return false }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        annotations[key]?[index].text = value
        annotations[key]?[index].modifiedAt = .now
        return true
    }

    @discardableResult
    func delete(id: UUID, document: NoteDocument?) -> Bool {
        guard let key = document?.persistenceKey,
              annotations[key]?.contains(where: { $0.id == id }) == true
        else { return false }
        annotations[key]?.removeAll { $0.id == id }
        if annotations[key]?.isEmpty == true {
            annotations[key] = nil
        }
        return true
    }

    @discardableResult
    func toggleResolution(id: UUID, document: NoteDocument?) -> Bool {
        guard let key = document?.persistenceKey,
              let index = annotations[key]?.firstIndex(where: { $0.id == id }),
              var annotation = annotations[key]?[index]
        else { return false }
        annotation.resolvedAt = annotation.isResolved ? nil : .now
        annotation.modifiedAt = .now
        annotations[key]?[index] = annotation
        return true
    }

    @discardableResult
    func relink(
        id: UUID,
        selection: EditorTextSelection,
        document: NoteDocument,
        documentText: String
    ) -> Bool {
        let key = document.persistenceKey
        guard let index = annotations[key]?.firstIndex(where: { $0.id == id }),
              let anchor = TextAnnotationAnchorResolver.makeAnchor(
                  selection: selection,
                  in: documentText
              ) else { return false }
        annotations[key]?[index].anchor = anchor
        annotations[key]?[index].modifiedAt = .now
        return true
    }

    @discardableResult
    func reanchor(
        document: NoteDocument?,
        from oldText: String,
        to newText: String,
        mutation: EditorTextMutation?
    ) -> Bool {
        guard oldText != newText,
              let key = document?.persistenceKey,
              let current = annotations[key],
              !current.isEmpty else { return false }
        let updated = repository.reanchor(
            current,
            from: oldText,
            to: newText,
            mutation: mutation
        )
        guard updated != current else { return false }
        annotations[key] = updated
        return true
    }

    func removeAnnotations<S: Sequence>(for keys: S) where S.Element == String {
        for key in keys {
            annotations[key] = nil
        }
    }

    @discardableResult
    func moveAnnotations(from oldKey: String, to newKey: String) -> Bool {
        guard let items = annotations.removeValue(forKey: oldKey) else {
            return false
        }
        annotations[newKey] = items
        return true
    }

    func loadLibraryIfNeeded(at root: URL) throws {
        try repository.loadLibraryIfNeeded(at: root, into: &annotations)
    }

    func loadExternalAnnotations(for document: NoteDocument) throws {
        guard let items = try repository.loadExternalAnnotations(for: document)
        else { return }
        annotations[document.persistenceKey] = items.isEmpty ? nil : items
    }

    @discardableResult
    func reconcileMovedDocuments(
        in root: URL,
        documents: [NoteDocument]
    ) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath + "/"
        let staleEntries = annotations.filter { key, items in
            key.hasPrefix(prefix) &&
                !items.isEmpty &&
                !FileManager.default.fileExists(atPath: key)
        }
        guard !staleEntries.isEmpty else { return false }

        var availableDocuments = documents.filter {
            annotations[$0.persistenceKey]?.isEmpty != false
        }
        var migrated = false
        for (oldKey, items) in staleEntries {
            let distinctiveEnough = items.count > 1 ||
                items.contains { $0.anchor.selectedText.count >= 12 }
            guard distinctiveEnough else { continue }

            let matches = availableDocuments.filter { document in
                guard let text = try? knowledgeBase.read(document) else {
                    return false
                }
                return items.allSatisfy {
                    TextAnnotationAnchorResolver.resolve($0, in: text) != nil
                }
            }
            guard matches.count == 1, let destination = matches.first else {
                continue
            }
            annotations[oldKey] = nil
            annotations[destination.persistenceKey] = items
            availableDocuments.removeAll { $0.id == destination.id }
            migrated = true
        }
        return migrated
    }

    func save(
        libraryRoot: URL?,
        externalDocument: NoteDocument?
    ) {
        repository.save(
            annotations,
            libraryRoot: libraryRoot,
            externalDocument: externalDocument
        )
    }

    func saveSynchronously(
        libraryRoot: URL?,
        externalDocuments: [NoteDocument]
    ) throws {
        try repository.saveSynchronously(
            annotations,
            libraryRoot: libraryRoot,
            externalDocuments: externalDocuments
        )
    }

    func transitionToLibrary() {
        composerRequest = nil
        repository.transitionToLibrary()
    }
}
