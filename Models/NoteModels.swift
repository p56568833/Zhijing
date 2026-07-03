import Foundation

struct NoteDocument: Identifiable, Hashable, Codable, Sendable {
    let url: URL
    let relativePath: String
    let modifiedAt: Date
    let size: Int

    var id: String { relativePath }
    var title: String {
        url.deletingPathExtension().lastPathComponent
    }
    var folder: String {
        let value = (relativePath as NSString).deletingLastPathComponent
        return value == "." ? "" : value
    }
    var kindIcon: String {
        url.pathExtension.lowercased() == "md" ? "doc.richtext" : "doc.text"
    }
}

struct SearchHit: Identifiable, Hashable, Sendable {
    let id = UUID()
    let document: NoteDocument
    let excerpt: String
    let line: Int
    let score: Double
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
    case failed(String)

    var label: String {
        switch self {
        case .idle: "未修改"
        case .saving: "正在保存…"
        case .saved: "已保存"
        case .failed: "保存失败"
        }
    }
}

struct Revision: Identifiable, Hashable, Sendable {
    let url: URL
    let createdAt: Date
    var id: URL { url }
}

struct EditProposal: Identifiable, Sendable {
    let id = UUID()
    let documentPath: String
    let original: String
    let replacement: String
    let instruction: String
}
