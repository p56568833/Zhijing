import Foundation
import Observation

@MainActor
@Observable
final class ExternalConflictController {
    var conflict: ExternalFileConflict?

    private let knowledgeBase: KnowledgeBaseService
    private let documentSession: DocumentSessionController
    private let revisions: RevisionController

    init(
        knowledgeBase: KnowledgeBaseService,
        documentSession: DocumentSessionController,
        revisions: RevisionController
    ) {
        self.knowledgeBase = knowledgeBase
        self.documentSession = documentSession
        self.revisions = revisions
    }

    func evaluateChange(
        for document: NoteDocument,
        editorText: String,
        changedURLs: Set<URL>
    ) throws -> ExternalFileChange? {
        guard shouldCheck(document, changedURLs: changedURLs) else {
            return nil
        }
        let fileExists = FileManager.default.fileExists(
            atPath: document.url.path
        )
        let diskText = fileExists ? try knowledgeBase.read(document) : nil
        return ExternalFileReconciler.evaluate(
            loadedText: documentSession.loadedText,
            editorText: editorText,
            diskText: diskText,
            knownLocalWriteSignatures: documentSession.localWriteSignatures(
                for: document
            )
        )
    }

    func recordConflict(
        document: NoteDocument,
        localText: String,
        diskText: String?
    ) {
        conflict = ExternalFileConflict(
            document: document,
            localText: localText,
            diskText: diskText,
            detectedAt: .now
        )
    }

    func keepLocalVersion(editorText: String) throws -> NoteDocument? {
        guard let conflict else { return nil }
        if let diskText = conflict.diskText {
            _ = try revisions.createSnapshot(
                text: diskText,
                document: conflict.document,
                name: "外部修改（冲突备份）"
            )
        }
        let refreshed = try documentSession.writeSynchronously(
            editorText,
            to: conflict.document,
            using: knowledgeBase
        )
        documentSession.loadedText = editorText
        revisions.load(for: conflict.document)
        self.conflict = nil
        return refreshed
    }

    func loadExternalVersion(editorText: String) throws -> (
        document: NoteDocument,
        text: String
    )? {
        guard let conflict, let diskText = conflict.diskText else {
            return nil
        }
        _ = try revisions.createSnapshot(
            text: editorText,
            document: conflict.document,
            name: "冲突前的本地版本"
        )
        documentSession.loadedText = diskText
        revisions.load(for: conflict.document)
        self.conflict = nil
        return (conflict.document, diskText)
    }

    func clear() {
        conflict = nil
    }

    private func shouldCheck(
        _ document: NoteDocument,
        changedURLs: Set<URL>
    ) -> Bool {
        guard !changedURLs.isEmpty else { return true }
        let documentPath = document.url.standardizedFileURL.path
        let parentPath = document.url.deletingLastPathComponent()
            .standardizedFileURL.path
        return changedURLs.contains { url in
            let path = url.standardizedFileURL.path
            return path == documentPath || path == parentPath
        }
    }
}
