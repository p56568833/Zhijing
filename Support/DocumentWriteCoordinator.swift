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
    ) async throws -> Int {
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
    ) throws -> Int {
        try queue.sync {
            try Self.performWrite(text, to: document, using: service)
        }
    }

    private static func performWrite(
        _ text: String,
        to document: NoteDocument,
        using service: KnowledgeBaseService
    ) throws -> Int {
        try service.write(text, to: document)
        return (try? document.url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            ?? document.size
    }
}
