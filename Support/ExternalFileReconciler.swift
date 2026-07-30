import Foundation

enum ExternalFileChange: Equatable, Sendable {
    case unchanged
    case localChangesOnly
    case synchronized(String)
    case localWriteObserved(String)
    case reloadFromDisk(String)
    case conflict(String)
    case removedCleanly
    case removedWithLocalChanges
}

struct DocumentContentSignature: Hashable, Sendable {
    let utf16Count: Int
    let contentHash: Int

    init(_ text: String) {
        utf16Count = text.utf16.count
        contentHash = text.hashValue
    }
}

enum ExternalFileReconciler {
    static func evaluate(
        loadedText: String,
        editorText: String,
        diskText: String?,
        knownLocalWriteSignatures: Set<DocumentContentSignature> = []
    ) -> ExternalFileChange {
        guard let diskText else {
            return editorText == loadedText
                ? .removedCleanly
                : .removedWithLocalChanges
        }
        if diskText == editorText {
            return .synchronized(diskText)
        }
        if diskText == loadedText {
            return editorText == loadedText ? .unchanged : .localChangesOnly
        }
        if knownLocalWriteSignatures.contains(DocumentContentSignature(diskText)) {
            return .localWriteObserved(diskText)
        }
        if editorText == loadedText {
            return .reloadFromDisk(diskText)
        }
        return .conflict(diskText)
    }
}
