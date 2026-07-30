import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceNavigationController {
    var openDocumentPaths: [String]
    var externalDocuments: [NoteDocument]
    var isComparisonVisible: Bool
    var comparisonDocumentPath: String?
    var comparisonText = ""

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        openDocumentPaths = defaults.stringArray(forKey: Keys.openDocumentPaths) ?? []
        externalDocuments = (
            defaults.stringArray(forKey: Keys.externalDocumentPaths) ?? []
        ).compactMap {
            Self.makeExternalDocument(at: URL(filePath: $0))
        }
        isComparisonVisible = defaults.object(
            forKey: Keys.comparisonVisible
        ) as? Bool ?? false
        comparisonDocumentPath = defaults.string(
            forKey: Keys.comparisonDocumentPath
        )
    }

    func openDocuments(in documents: [NoteDocument]) -> [NoteDocument] {
        var indexed: [String: NoteDocument] = [:]
        for document in documents {
            indexed[document.relativePath] = document
        }
        let libraryDocuments = openDocumentPaths.compactMap { indexed[$0] }
        return libraryDocuments + externalDocuments.filter { external in
            !libraryDocuments.contains(where: { $0.id == external.id })
        }
    }

    func persistOpenDocuments() {
        defaults.set(openDocumentPaths, forKey: Keys.openDocumentPaths)
    }

    func persistExternalDocuments() {
        defaults.set(
            externalDocuments.map { $0.url.standardizedFileURL.path },
            forKey: Keys.externalDocumentPaths
        )
    }

    func persistComparisonVisibility() {
        defaults.set(isComparisonVisible, forKey: Keys.comparisonVisible)
    }

    func persistComparisonDocument() {
        if let comparisonDocumentPath {
            defaults.set(comparisonDocumentPath, forKey: Keys.comparisonDocumentPath)
        } else {
            defaults.removeObject(forKey: Keys.comparisonDocumentPath)
        }
    }

    func resetForLibraryTransition() {
        openDocumentPaths = []
        comparisonDocumentPath = nil
        comparisonText = ""
        isComparisonVisible = false
        defaults.removeObject(forKey: Keys.openDocumentPaths)
        defaults.removeObject(forKey: Keys.comparisonDocumentPath)
        defaults.set(false, forKey: Keys.comparisonVisible)
    }

    static func makeExternalDocument(at url: URL) -> NoteDocument? {
        let url = url.standardizedFileURL
        guard NoteDocument.isSupportedFile(url),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try? url.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey,
        ])
        return NoteDocument(
            url: url,
            relativePath: url.path,
            modifiedAt: values?.contentModificationDate ?? .distantPast,
            size: values?.fileSize ?? 0
        )
    }

    private enum Keys {
        static let openDocumentPaths = "openDocumentPaths"
        static let externalDocumentPaths = "externalDocumentPaths"
        static let comparisonVisible = "comparisonVisible"
        static let comparisonDocumentPath = "comparisonDocumentPath"
    }
}
