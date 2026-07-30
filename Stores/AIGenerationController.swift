import Foundation
import Observation

struct AIChatGenerationRequest: Sendable {
    let question: String
    let document: NoteDocument
    let currentText: String
    let selection: EditorTextSelection?
    let annotations: [TextAnnotation]
    let scope: RetrievalScope
    let documents: [NoteDocument]
    let configuration: AIConfiguration
}

struct AISelectionProposalRequest: Sendable {
    let instruction: String
    let document: NoteDocument
    let originalText: String
    let selection: EditorTextSelection
    let annotations: [TextAnnotation]
    let documents: [NoteDocument]
    let configuration: AIConfiguration
}

struct AIDocumentProposalRequest: Sendable {
    let instruction: String
    let documentPath: String
    let originalText: String
    let annotations: [TextAnnotation]
    let configuration: AIConfiguration
}

@MainActor
@Observable
final class AIGenerationController {
    var chats: [String: [ChatMessage]] = [:]
    private(set) var isGenerating = false
    private(set) var retrievalStatus = ""

    var canCancel: Bool { generationTask != nil }

    private let ai: AIService
    private let knowledgeBase: KnowledgeBaseService
    private let persistence: ChatPersistenceService
    @ObservationIgnored
    private var generationTask: Task<Void, Never>?
    @ObservationIgnored
    private var generationID: UUID?

    init(
        ai: AIService = .init(),
        knowledgeBase: KnowledgeBaseService,
        persistence: ChatPersistenceService = .init()
    ) {
        self.ai = ai
        self.knowledgeBase = knowledgeBase
        self.persistence = persistence
    }

    func loadChats(legacyData: Data?) throws {
        chats = try persistence.loadStrict(legacyData: legacyData)
    }

    func messages(for documentKey: String?) -> [ChatMessage] {
        guard let documentKey else { return [] }
        return chats[documentKey] ?? []
    }

    func persistChats() {
        persistence.save(chats)
    }

    func saveSynchronously() throws {
        try persistence.saveSynchronously(chats)
    }

    func clearChat(for documentKey: String) {
        chats[documentKey] = []
        persistChats()
    }

    func removeChats(for documentKeys: some Sequence<String>) {
        for key in documentKeys {
            chats[key] = nil
        }
        persistChats()
    }

    func moveChat(from oldKey: String, to newKey: String) {
        guard let messages = chats.removeValue(forKey: oldKey) else { return }
        chats[newKey] = messages
        persistChats()
    }

    @discardableResult
    func sendMessage(
        _ request: AIChatGenerationRequest,
        onProposal: @escaping @MainActor (EditProposal) -> Void,
        onDeepSeekCompletion: @escaping @MainActor () async -> Void
    ) -> Bool {
        guard let operationID = beginGeneration() else { return false }
        let key = request.document.persistenceKey
        let history = chats[key] ?? []
        chats[key, default: []].append(
            ChatMessage(role: .user, text: request.question)
        )
        persistChats()
        retrievalStatus = "正在搜索知识库…"
        let assistantMessageID = UUID()
        let service = knowledgeBase
        let ai = ai

        generationTask = Task { [weak self] in
            guard let self else { return }
            defer { finishGeneration(operationID) }
            let chunks = await Task.detached {
                service.retrieve(
                    query: request.question,
                    documents: request.documents,
                    currentDocument: request.document,
                    scope: request.scope
                )
            }.value
            guard isCurrent(operationID) else { return }
            retrievalStatus = "搜索了 \(Set(chunks.map(\.filePath)).count) 篇笔记，引用了 \(chunks.count) 个片段"
            let currentContext = AIContextBuilder.answerContext(
                question: request.question,
                document: request.document,
                text: request.currentText,
                selection: request.selection,
                annotations: request.annotations
            )
            var streamedText = ""
            var didCreateAssistantMessage = false
            do {
                let stream = ai.answerStream(
                    question: request.question,
                    currentContext: currentContext,
                    history: history,
                    sources: chunks,
                    configuration: request.configuration
                )
                for try await event in stream {
                    try Task.checkCancellation()
                    switch event {
                    case .delta(let delta):
                        streamedText += delta
                        if !didCreateAssistantMessage {
                            chats[key, default: []].append(ChatMessage(
                                id: assistantMessageID,
                                role: .assistant,
                                text: streamedText,
                                sources: chunks
                            ))
                            didCreateAssistantMessage = true
                        } else {
                            updateAssistantMessage(
                                id: assistantMessageID,
                                documentPath: key,
                                text: streamedText,
                                sources: chunks
                            )
                        }
                    case .finished(let response):
                        let (displayText, extractedEdit) = try AIEditPatchProcessor
                            .extractFromChat(
                                response.text,
                                original: request.currentText
                            )
                        if didCreateAssistantMessage {
                            updateAssistantMessage(
                                id: assistantMessageID,
                                documentPath: key,
                                text: displayText,
                                sources: response.sources,
                                isGeneralKnowledge: response.usedGeneralKnowledge,
                                usage: response.usage,
                                cost: response.cost
                            )
                        } else {
                            chats[key, default: []].append(ChatMessage(
                                id: assistantMessageID,
                                role: .assistant,
                                text: displayText,
                                sources: response.sources,
                                isGeneralKnowledge: response.usedGeneralKnowledge,
                                usage: response.usage,
                                cost: response.cost
                            ))
                        }
                        persistChats()
                        if let extractedEdit {
                            onProposal(EditProposal(
                                documentPath: request.document.relativePath,
                                original: request.currentText,
                                replacement: extractedEdit,
                                instruction: request.question
                            ))
                        }
                    }
                }
                if request.configuration.provider == .deepSeek {
                    await onDeepSeekCompletion()
                }
            } catch is CancellationError {
                if didCreateAssistantMessage {
                    updateAssistantMessage(
                        id: assistantMessageID,
                        documentPath: key,
                        text: streamedText.isEmpty ? "已停止生成。" : streamedText
                    )
                    persistChats()
                }
            } catch {
                guard isCurrent(operationID) else { return }
                chats[key, default: []].append(ChatMessage(
                    role: .assistant,
                    text: "回答失败：\(error.localizedDescription)"
                ))
                persistChats()
            }
        }
        return true
    }

    @discardableResult
    func proposeSelectionEdit(
        _ request: AISelectionProposalRequest,
        onProposal: @escaping @MainActor (EditProposal) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) -> Bool {
        guard let operationID = beginGeneration() else { return false }
        retrievalStatus = "正在理解选区并判断所需上下文…"
        let service = knowledgeBase
        let ai = ai

        generationTask = Task { [weak self] in
            guard let self else { return }
            defer { finishGeneration(operationID) }
            let query = "\(request.instruction)\n\(request.selection.text)"
            let chunks = await Task.detached(priority: .userInitiated) {
                service.retrieve(
                    query: query,
                    documents: request.documents,
                    currentDocument: request.document,
                    scope: .library,
                    limit: 5
                )
            }.value
            guard isCurrent(operationID) else { return }
            retrievalStatus = chunks.isEmpty
                ? "未使用知识库资料"
                : "AI 已自行筛选 \(Set(chunks.map(\.filePath)).count) 篇相关资料"
            do {
                let application = try await ai.proposeSelectionEdit(
                    instruction: request.instruction,
                    currentText: request.originalText,
                    selectedText: request.selection.text,
                    surroundingContext: AIContextBuilder.surroundingContext(
                        in: request.originalText,
                        selection: request.selection.range
                    ),
                    annotationContext: AIContextBuilder.annotationContext(
                        annotations: request.annotations,
                        in: request.originalText
                    ),
                    sources: chunks,
                    configuration: request.configuration
                )
                guard isCurrent(operationID) else { return }
                let outsideEdits = application.edits.filter {
                    !AIContextBuilder.contains(
                        request.selection.range,
                        range: $0.range
                    )
                }
                let reasons = outsideEdits.compactMap(\.reason).filter {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                onProposal(EditProposal(
                    documentPath: request.document.relativePath,
                    original: request.originalText,
                    replacement: application.replacement,
                    instruction: request.instruction,
                    selectionLineRange: AIContextBuilder.lineRange(
                        for: request.selection.range,
                        in: request.originalText
                    ),
                    selectionRange: request.selection.range,
                    outsideSelectionReason: reasons.isEmpty && !outsideEdits.isEmpty
                        ? "为保证上下文衔接，AI 建议同时调整这部分。"
                        : reasons.joined(separator: "；")
                ))
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent(operationID) else { return }
                onError(error.localizedDescription)
            }
        }
        return true
    }

    @discardableResult
    func proposeDocumentEdit(
        _ request: AIDocumentProposalRequest,
        onProposal: @escaping @MainActor (EditProposal) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) -> Bool {
        guard let operationID = beginGeneration() else { return false }
        let ai = ai
        generationTask = Task { [weak self] in
            guard let self else { return }
            defer { finishGeneration(operationID) }
            do {
                let replacement = try await ai.proposeEdit(
                    instruction: request.instruction,
                    currentText: request.originalText,
                    annotationContext: AIContextBuilder.annotationContext(
                        annotations: request.annotations,
                        in: request.originalText
                    ),
                    configuration: request.configuration
                )
                guard isCurrent(operationID) else { return }
                onProposal(EditProposal(
                    documentPath: request.documentPath,
                    original: request.originalText,
                    replacement: replacement,
                    instruction: request.instruction
                ))
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent(operationID) else { return }
                onError(error.localizedDescription)
            }
        }
        return true
    }

    func cancelGeneration() {
        generationID = nil
        let task = generationTask
        generationTask = nil
        task?.cancel()
        isGenerating = false
        retrievalStatus = "已停止生成"
    }

    private func beginGeneration() -> UUID? {
        guard generationID == nil else { return nil }
        let id = UUID()
        generationID = id
        isGenerating = true
        return id
    }

    private func finishGeneration(_ id: UUID) {
        guard generationID == id else { return }
        generationID = nil
        generationTask = nil
        isGenerating = false
    }

    private func isCurrent(_ id: UUID) -> Bool {
        !Task.isCancelled && generationID == id
    }

    private func updateAssistantMessage(
        id: UUID,
        documentPath: String,
        text: String,
        sources: [RetrievedChunk]? = nil,
        isGeneralKnowledge: Bool? = nil,
        usage: AIUsage? = nil,
        cost: AIUsageCost? = nil
    ) {
        guard let index = chats[documentPath]?.firstIndex(where: {
            $0.id == id
        }) else { return }
        let old = chats[documentPath]?[index]
        chats[documentPath]?[index] = ChatMessage(
            id: id,
            role: .assistant,
            text: text,
            createdAt: old?.createdAt ?? .now,
            sources: sources ?? old?.sources ?? [],
            isGeneralKnowledge: isGeneralKnowledge
                ?? old?.isGeneralKnowledge
                ?? false,
            usage: usage ?? old?.usage,
            cost: cost ?? old?.cost
        )
    }
}
