import Foundation

@MainActor
final class DocumentSessionController {
    private struct RecentLocalWrite {
        let id: UUID
        let signature: DocumentContentSignature
        let expiresAt: Date
    }

    private let writer = DocumentWriteCoordinator()
    private var autosaveTask: Task<Void, Never>?
    private var recentLocalWrites: [String: [RecentLocalWrite]] = [:]

    var loadedText = ""

    func cancelAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    func scheduleAutosave(
        delay: Duration,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        cancelAutosave()
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    func reset() {
        cancelAutosave()
        loadedText = ""
    }

    func writeSynchronously(
        _ text: String,
        to document: NoteDocument,
        using service: KnowledgeBaseService
    ) throws -> NoteDocument {
        let writeID = trackLocalWrite(text, to: document)
        do {
            return try writer.writeSynchronously(text, to: document, using: service)
        } catch {
            forgetLocalWrite(writeID, for: document)
            throw error
        }
    }

    func write(
        _ text: String,
        to document: NoteDocument,
        using service: KnowledgeBaseService
    ) async throws -> NoteDocument {
        let writeID = trackLocalWrite(text, to: document)
        do {
            return try await writer.write(text, to: document, using: service)
        } catch {
            forgetLocalWrite(writeID, for: document)
            throw error
        }
    }

    func localWriteSignatures(
        for document: NoteDocument
    ) -> Set<DocumentContentSignature> {
        let path = document.url.standardizedFileURL.path
        pruneLocalWrites(forPath: path)
        return Set(recentLocalWrites[path, default: []].map(\.signature))
    }

    private func trackLocalWrite(_ text: String, to document: NoteDocument) -> UUID {
        let path = document.url.standardizedFileURL.path
        pruneLocalWrites(forPath: path)
        let write = RecentLocalWrite(
            id: UUID(),
            signature: DocumentContentSignature(text),
            expiresAt: .now.addingTimeInterval(60)
        )
        var writes = recentLocalWrites[path] ?? []
        writes.append(write)
        if writes.count > 8 {
            writes.removeFirst(writes.count - 8)
        }
        recentLocalWrites[path] = writes
        return write.id
    }

    private func forgetLocalWrite(_ id: UUID, for document: NoteDocument) {
        let path = document.url.standardizedFileURL.path
        let remaining = (recentLocalWrites[path] ?? []).filter { $0.id != id }
        recentLocalWrites[path] = remaining.isEmpty ? nil : remaining
    }

    private func pruneLocalWrites(forPath path: String) {
        let now = Date.now
        let valid = (recentLocalWrites[path] ?? []).filter { $0.expiresAt > now }
        recentLocalWrites[path] = valid.isEmpty ? nil : valid
    }
}
