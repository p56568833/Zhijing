import Foundation
import Observation

@MainActor
@Observable
final class RevisionController {
    var revisions: [Revision] = []

    private let service: KnowledgeBaseService

    init(service: KnowledgeBaseService) {
        self.service = service
    }

    func load(for document: NoteDocument?) {
        revisions = document.map(service.revisions) ?? []
    }

    @discardableResult
    func createSnapshot(
        text: String,
        document: NoteDocument,
        name: String? = nil
    ) throws -> URL {
        let url = try service.createSnapshot(
            text: text,
            document: document,
            name: name
        )
        load(for: document)
        return url
    }

    func revisionText(_ revision: Revision) throws -> String {
        try service.revisionText(revision)
    }

    func prepareRestore(
        _ revision: Revision,
        currentText: String,
        document: NoteDocument
    ) throws -> String {
        _ = try createSnapshot(
            text: currentText,
            document: document,
            name: "恢复前自动备份"
        )
        return try service.revisionText(revision)
    }

    func reset() {
        revisions = []
    }
}
