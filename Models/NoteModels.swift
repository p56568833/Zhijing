import Foundation

struct NoteDocument: Identifiable, Hashable, Codable, Sendable {
    let url: URL
    let relativePath: String
    let modifiedAt: Date
    let size: Int

    var id: String { url.standardizedFileURL.path }
    var persistenceKey: String { id }
    var title: String {
        url.deletingPathExtension().lastPathComponent
    }
    var folder: String {
        let value = (relativePath as NSString).deletingLastPathComponent
        return value == "." ? "" : value
    }
    var kindIcon: String {
        switch url.pathExtension.lowercased() {
        case "md", "markdown":
            "doc.richtext"
        case "srt":
            "captions.bubble"
        default:
            "doc.text"
        }
    }

    static let supportedFileExtensions: Set<String> = ["md", "markdown", "txt", "srt"]

    static func isSupportedFile(_ url: URL) -> Bool {
        supportedFileExtensions.contains(url.pathExtension.lowercased())
    }
}

struct DocumentOpenRequest: Equatable, Sendable {
    let root: URL
    let relativePaths: [String]
    let externalURLs: [URL]
    let firstURL: URL
}

enum DocumentOpenRequestResolver {
    static func resolve(
        urls: [URL],
        currentLibrary: URL?
    ) -> DocumentOpenRequest? {
        var seenPaths: Set<String> = []
        let documents = urls.map(\.standardizedFileURL).filter {
            NoteDocument.isSupportedFile($0) && seenPaths.insert($0.path).inserted
        }
        guard let first = documents.first else { return nil }

        let currentRoot = currentLibrary?.standardizedFileURL
        let root = currentRoot
            ?? first.deletingLastPathComponent().standardizedFileURL

        let rootPath = root.path
        let libraryDocuments = documents.filter { isContained($0, in: root) }
        let relativePaths = libraryDocuments.map { url in
            String(url.path.dropFirst(rootPath.count + 1))
        }
        let externalURLs = documents.filter { !isContained($0, in: root) }
        return DocumentOpenRequest(
            root: root,
            relativePaths: relativePaths,
            externalURLs: externalURLs,
            firstURL: first
        )
    }

    private static func isContained(_ url: URL, in root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path.hasPrefix(rootPath + "/")
    }
}

struct SearchHit: Identifiable, Hashable, Sendable {
    let id = UUID()
    let document: NoteDocument
    let excerpt: String
    let line: Int
    let score: Double
}

struct LibraryTreeItem: Identifiable, Hashable, Sendable {
    enum Content: Hashable, Sendable {
        case folder(String)
        case document(NoteDocument)
    }

    let content: Content
    let children: [LibraryTreeItem]?

    var id: String {
        switch content {
        case .folder(let path):
            "folder:\(path)"
        case .document(let document):
            "document:\(document.id)"
        }
    }
}

enum LibraryTreeBuilder {
    static func build(
        folders: [String],
        documents: [NoteDocument]
    ) -> [LibraryTreeItem] {
        var folderPaths: Set<String> = []
        for path in folders + documents.map(\.folder) where !path.isEmpty {
            var current = path
            while !current.isEmpty {
                folderPaths.insert(current)
                current = parentPath(of: current)
            }
        }

        let documentsByFolder = Dictionary(grouping: documents, by: \.folder)
        let childFoldersByParent = Dictionary(grouping: folderPaths) {
            parentPath(of: $0)
        }

        func children(of parent: String) -> [LibraryTreeItem] {
            let childFolders = (childFoldersByParent[parent] ?? [])
                .sorted {
                    displayName(of: $0).localizedStandardCompare(
                        displayName(of: $1)
                    ) == .orderedAscending
                }
                .map { path in
                    let nestedItems = children(of: path)
                    return LibraryTreeItem(
                        content: .folder(path),
                        children: nestedItems.isEmpty ? nil : nestedItems
                    )
                }

            let directDocuments = (documentsByFolder[parent] ?? [])
                .sorted {
                    $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
                .map {
                    LibraryTreeItem(content: .document($0), children: nil)
                }

            return childFolders + directDocuments
        }

        return children(of: "")
    }

    private static func parentPath(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }

    private static func displayName(of path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

struct RetrievedChunk: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let filePath: String
    let fileName: String
    let heading: String?
    let text: String
    let line: Int
    let score: Double

    init(
        id: UUID = UUID(),
        filePath: String,
        fileName: String,
        heading: String?,
        text: String,
        line: Int,
        score: Double
    ) {
        self.id = id
        self.filePath = filePath
        self.fileName = fileName
        self.heading = heading
        self.text = text
        self.line = line
        self.score = score
    }
}

struct EditorNavigationRequest: Equatable, Sendable {
    let id: UUID
    let documentID: String
    let line: Int?
    let selectionRange: NSRange?
    let verticalFraction: Double?

    init(
        id: UUID = UUID(),
        documentID: String,
        line: Int,
        verticalFraction: Double? = nil
    ) {
        self.id = id
        self.documentID = documentID
        self.line = line
        self.selectionRange = nil
        self.verticalFraction = verticalFraction
    }

    init(id: UUID = UUID(), documentID: String, selectionRange: NSRange) {
        self.id = id
        self.documentID = documentID
        self.line = nil
        self.selectionRange = selectionRange
        self.verticalFraction = nil
    }
}

struct EditorTextSelection: Equatable, Sendable {
    let documentID: String
    let range: NSRange
    let text: String

    var isEmpty: Bool { range.length == 0 || text.isEmpty }
}

struct TextAnnotation: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let anchor: TextAnnotationAnchor
    var text: String
    let createdAt: Date
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        anchor: TextAnnotationAnchor,
        text: String,
        createdAt: Date = .now,
        modifiedAt: Date = .now
    ) {
        self.id = id
        self.anchor = anchor
        self.text = text
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

struct TextAnnotationAnchor: Hashable, Codable, Sendable {
    let selectedText: String
    let utf16Location: Int
    let prefix: String
    let suffix: String
}

struct ResolvedTextAnnotation: Identifiable, Equatable, Sendable {
    let annotation: TextAnnotation
    let range: NSRange

    var id: UUID { annotation.id }
}

struct DocumentFindOptions: Equatable, Sendable {
    var query = ""
    var matchCase = false
    var wholeWord = false

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct DocumentFindResult: Equatable, Sendable {
    var matchCount = 0
    var selectedIndex: Int?

    var displayText: String {
        guard matchCount > 0 else { return "无结果" }
        return "\(selectedIndex.map { $0 + 1 } ?? 1) / \(matchCount)"
    }
}

enum DocumentFindDirection: Sendable {
    case previous
    case next
}

enum DocumentFindCommand: Sendable {
    case show
    case previous
    case next
}

struct DocumentFindNavigationRequest: Equatable, Sendable {
    let id = UUID()
    let direction: DocumentFindDirection
}

enum AISelectionEditAction: String, CaseIterable, Sendable {
    case polish
    case condense
    case expand
    case logic
    case custom

    var title: String {
        switch self {
        case .polish: "润色表达"
        case .condense: "压缩冗余"
        case .expand: "扩写说明"
        case .logic: "调整逻辑"
        case .custom: "自定义修改…"
        }
    }

    var instruction: String? {
        switch self {
        case .polish: "润色所选内容，使表达清晰自然，保持原意、事实和 Markdown 结构。"
        case .condense: "压缩所选内容的重复和冗余表达，保留重要信息。"
        case .expand: "扩写所选内容，只展开已有观点，不添加无来源的新事实。"
        case .logic: "调整所选内容的论证和句子顺序，使逻辑更清楚。"
        case .custom: nil
        }
    }
}

struct SelectionEditRequest: Identifiable, Sendable {
    let id = UUID()
    let selection: EditorTextSelection
}

enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
}

struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let role: MessageRole
    let text: String
    let createdAt: Date
    let sources: [RetrievedChunk]
    let isGeneralKnowledge: Bool
    let usage: AIUsage?
    let cost: AIUsageCost?

    init(
        id: UUID = UUID(),
        role: MessageRole,
        text: String,
        createdAt: Date = .now,
        sources: [RetrievedChunk] = [],
        isGeneralKnowledge: Bool = false,
        usage: AIUsage? = nil,
        cost: AIUsageCost? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.sources = sources
        self.isGeneralKnowledge = isGeneralKnowledge
        self.usage = usage
        self.cost = cost
    }
}

enum RetrievalScope: String, CaseIterable, Identifiable, Codable, Sendable {
    case library = "整个知识库"
    case currentFolder = "当前文件夹"
    var id: String { rawValue }
}

enum SaveState: Equatable, Sendable {
    case idle
    case saving
    case saved(Date)
    case reviewingExternalChange
    case failed(String)

    var label: String {
        switch self {
        case .idle: "未修改"
        case .saving: "正在保存…"
        case .saved: "已保存"
        case .reviewingExternalChange: "等待确认外部修改"
        case .failed: "保存失败"
        }
    }
}

struct Revision: Identifiable, Hashable, Sendable {
    let url: URL
    let createdAt: Date
    let name: String?

    init(url: URL, createdAt: Date, name: String? = nil) {
        self.url = url
        self.createdAt = createdAt
        self.name = name
    }

    var id: URL { url }

    var displayName: String {
        let cleaned = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty
            ? createdAt.formatted(date: .abbreviated, time: .shortened)
            : cleaned
    }
}

struct ExternalFileConflict: Identifiable, Sendable {
    let id = UUID()
    let document: NoteDocument
    let localText: String
    let diskText: String?
    let detectedAt: Date

    var fileWasRemoved: Bool { diskText == nil }
}

enum EditProposalSource: Equatable, Sendable {
    case assistant
    case externalFile
}

struct EditProposal: Identifiable, Sendable {
    let id: UUID
    let documentPath: String
    let original: String
    let replacement: String
    let instruction: String
    let selectionLineRange: Range<Int>?
    let selectionRange: NSRange?
    let outsideSelectionReason: String?
    let source: EditProposalSource
    let expectedDiskText: String?

    init(
        id: UUID = UUID(),
        documentPath: String,
        original: String,
        replacement: String,
        instruction: String,
        selectionLineRange: Range<Int>? = nil,
        selectionRange: NSRange? = nil,
        outsideSelectionReason: String? = nil,
        source: EditProposalSource = .assistant,
        expectedDiskText: String? = nil
    ) {
        self.id = id
        self.documentPath = documentPath
        self.original = original
        self.replacement = replacement
        self.instruction = instruction
        self.selectionLineRange = selectionLineRange
        self.selectionRange = selectionRange
        self.outsideSelectionReason = outsideSelectionReason
        self.source = source
        self.expectedDiskText = expectedDiskText
    }

    func canApply(to documentPath: String, currentText: String) -> Bool {
        self.documentPath == documentPath && original == currentText
    }
}
