import Foundation

final class DocumentWriteCoordinator: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.zhijing.document-writer",
        qos: .utility
    )

    func write(
        _ text: String,
        to document: NoteDocument,
        using service: KnowledgeBaseService
    ) async throws -> NoteDocument {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try Self.performWrite(text, to: document, using: service)
                })
            }
        }
    }

    func writeSynchronously(
        _ text: String,
        to document: NoteDocument,
        using service: KnowledgeBaseService
    ) throws -> NoteDocument {
        try queue.sync {
            try Self.performWrite(text, to: document, using: service)
        }
    }

    private static func performWrite(
        _ text: String,
        to document: NoteDocument,
        using service: KnowledgeBaseService
    ) throws -> NoteDocument {
        try service.write(text, to: document)
    }
}
