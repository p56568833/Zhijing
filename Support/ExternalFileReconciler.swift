import Foundation

enum ExternalFileChange: Equatable, Sendable {
    case unchanged
    case localChangesOnly
    case synchronized(String)
    case reloadFromDisk(String)
    case conflict(String)
    case removedCleanly
    case removedWithLocalChanges
}

enum ExternalFileReconciler {
    static func evaluate(
        loadedText: String,
        editorText: String,
        diskText: String?
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
        if editorText == loadedText {
            return .reloadFromDisk(diskText)
        }
        return .conflict(diskText)
    }
}
