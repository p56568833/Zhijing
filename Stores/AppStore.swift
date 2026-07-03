import AppKit
import Foundation
import Observation
import SwiftUI

enum AppColorScheme: String, CaseIterable {
    case system
    case light
    case dark

    var name: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
@Observable
final class AppStore {
    var libraryURL: URL?
    var documents: [NoteDocument] = []
    var selectedDocument: NoteDocument?
    var editorText = ""
    var searchQuery = ""
    var searchResults: [SearchHit] = []
    var favorites: Set<String> = []
    var saveState: SaveState = .idle
    var isIndexing = false
    var isAssistantVisible = true
    var isSidebarVisible = true
    var colorScheme = AppColorScheme.system {
        didSet { defaults.set(colorScheme.rawValue, forKey: Keys.colorScheme) }
    }
    var isPreviewMode = false
    var retrievalScope: RetrievalScope = .library
    var chats: [String: [ChatMessage]] = [:]
    var isGenerating = false
    var retrievalStatus = ""
    var errorMessage: String?
    var editProposal: EditProposal?
    var revisions: [Revision] = []
    var provider: AIProviderPreset = .openAI
    var isTestingConnection = false
    var connectionTestSucceeded = false
    var connectionTestError: String?
    var accountBalances: [AIAccountBalance] = []
    var balanceError: String?
    var isRefreshingBalance = false

    var model = "gpt-4.1-mini" {
        didSet { defaults.set(model, forKey: Keys.model) }
    }
    var endpoint = "https://api.openai.com/v1" {
        didSet { defaults.set(endpoint, forKey: Keys.endpoint) }
    }
    var excludedFoldersText = ".git, node_modules" {
        didSet { defaults.set(excludedFoldersText, forKey: Keys.excludedFolders) }
    }
    var apiKey = "" {
        didSet {
            guard apiKey != oldValue else { return }
            try? KeychainStore.save(apiKey, account: "openai-api-key")
        }
    }

    private let defaults = UserDefaults.standard
    private let knowledgeBase = KnowledgeBaseService()
    private let ai = AIService()
    private var saveTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var loadedText = ""
    private var lastBalanceRefresh: Date?
    private var libraryRefreshID = UUID()

    var currentMessages: [ChatMessage] {
        guard let key = selectedDocument?.relativePath else { return [] }
        return chats[key] ?? []
    }

    var latestUsage: AIUsage? {
        currentMessages.reversed().compactMap(\.usage).first
    }

    var currentConversationCost: AIUsageCost? {
        let costs = currentMessages.compactMap(\.cost)
        guard let currency = costs.first?.currency else { return nil }
        let matching = costs.filter { $0.currency == currency }
        return AIUsageCost(
            amount: matching.reduce(0) { $0 + $1.amount },
            currency: currency
        )
    }

    var recentDocuments: [NoteDocument] {
        documents.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(8).map { $0 }
    }

    var favoriteDocuments: [NoteDocument] {
        documents.filter { favorites.contains($0.relativePath) }
    }

    init() {
        provider = AIProviderPreset(
            rawValue: defaults.string(forKey: Keys.provider) ?? ""
        ) ?? Self.inferProvider(from: defaults.string(forKey: Keys.endpoint))
        model = defaults.string(forKey: Keys.model) ?? "gpt-4.1-mini"
        endpoint = defaults.string(forKey: Keys.endpoint) ?? "https://api.openai.com/v1"
        excludedFoldersText = defaults.string(forKey: Keys.excludedFolders) ?? ".git, node_modules"
        apiKey = KeychainStore.read(account: "openai-api-key")
        favorites = Set(defaults.stringArray(forKey: Keys.favorites) ?? [])
        chats = Self.loadChats(defaults: defaults)
        isAssistantVisible = defaults.object(forKey: Keys.assistantVisible) as? Bool ?? true
        isSidebarVisible = defaults.object(forKey: Keys.sidebarVisible) as? Bool ?? true
        colorScheme = AppColorScheme(rawValue: defaults.string(forKey: Keys.colorScheme) ?? "") ?? .system

        if let presetEndpoint = provider.endpoint {
            endpoint = presetEndpoint
            if !provider.models.contains(where: { $0.id == model }) {
                model = provider.defaultModel
            }
        }

        if let path = defaults.string(forKey: Keys.libraryPath) {
            let url = URL(filePath: path, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: url.path) {
                libraryURL = url
                Task { await refreshLibrary(selecting: defaults.string(forKey: Keys.selectedPath)) }
            }
        }
    }

    func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.title = "选择 Markdown 知识库"
        panel.message = "知境只会读取此文件夹中的 Markdown 与纯文本文件"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard flushSave() else { return }
        clearDocumentSelection()
        libraryURL = url
        defaults.set(url.path, forKey: Keys.libraryPath)
        Task { await refreshLibrary() }
    }

    func selectProvider(_ newProvider: AIProviderPreset) {
        provider = newProvider
        defaults.set(newProvider.rawValue, forKey: Keys.provider)
        if let presetEndpoint = newProvider.endpoint {
            endpoint = presetEndpoint
            if !newProvider.models.contains(where: { $0.id == model }) {
                model = newProvider.defaultModel
            }
        }
        accountBalances = []
        balanceError = nil
        lastBalanceRefresh = nil
        resetConnectionTest()
    }

    func selectModel(_ newModel: String) {
        model = newModel
        if let presetEndpoint = provider.endpoint {
            endpoint = presetEndpoint
        }
        resetConnectionTest()
    }

    func testAIConnection(apiKey: String) async {
        let cleanedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = cleanedKey
        isTestingConnection = true
        connectionTestSucceeded = false
        connectionTestError = nil
        defer { isTestingConnection = false }

        do {
            try await ai.testConnection(configuration: configuration)
            connectionTestSucceeded = true
            if provider == .deepSeek {
                await refreshAccountBalance(force: true)
            }
        } catch {
            connectionTestError = error.localizedDescription
        }
    }

    func resetConnectionTest() {
        connectionTestSucceeded = false
        connectionTestError = nil
    }

    func refreshAccountBalance(force: Bool = false) async {
        guard provider == .deepSeek, !apiKey.isEmpty, !isRefreshingBalance else { return }
        if !force, let lastBalanceRefresh, Date().timeIntervalSince(lastBalanceRefresh) < 60 {
            return
        }
        isRefreshingBalance = true
        balanceError = nil
        defer { isRefreshingBalance = false }
        do {
            accountBalances = try await ai.fetchDeepSeekBalance(apiKey: apiKey)
            lastBalanceRefresh = .now
        } catch {
            balanceError = error.localizedDescription
        }
    }

    func openDocument(at url: URL) {
        let fileURL = url.standardizedFileURL
        let supportedExtensions = ["md", "markdown", "txt"]
        guard supportedExtensions.contains(fileURL.pathExtension.lowercased()) else {
            errorMessage = "知境目前只能打开 Markdown 或纯文本文件。"
            return
        }

        let currentRoot = libraryURL?.standardizedFileURL
        let isInCurrentLibrary = currentRoot.map {
            fileURL.path == $0.path || fileURL.path.hasPrefix($0.path + "/")
        } ?? false
        let root = isInCurrentLibrary ? currentRoot! : fileURL.deletingLastPathComponent()
        let relativePath = String(fileURL.path.dropFirst(min(fileURL.path.count, root.path.count + 1)))

        if !isInCurrentLibrary {
            guard flushSave() else { return }
            clearDocumentSelection()
            libraryURL = root
            defaults.set(root.path, forKey: Keys.libraryPath)
        }
        Task { await refreshLibrary(selecting: relativePath) }
    }

    func refreshLibrary(selecting relativePath: String? = nil) async {
        guard let libraryURL else { return }
        let refreshID = UUID()
        libraryRefreshID = refreshID
        isIndexing = true
        defer {
            if libraryRefreshID == refreshID {
                isIndexing = false
            }
        }
        do {
            let excluded = excludedFolders
            let scanned = try await Task.detached {
                try KnowledgeBaseService().scan(root: libraryURL, excludedFolders: excluded)
            }.value
            guard libraryRefreshID == refreshID,
                  self.libraryURL?.standardizedFileURL == libraryURL.standardizedFileURL
            else { return }
            documents = scanned
            let targetPath = relativePath ?? selectedDocument?.relativePath
            if let targetPath, let target = documents.first(where: { $0.relativePath == targetPath }) {
                select(target)
            } else {
                if selectedDocument != nil {
                    saveTask?.cancel()
                    clearDocumentSelection()
                    errorMessage = "当前文稿已不在知识库中，可能被其他应用移动或删除。"
                }
                if let first = documents.first {
                    select(first)
                } else {
                    defaults.removeObject(forKey: Keys.selectedPath)
                    saveState = .idle
                }
            }
        } catch {
            guard libraryRefreshID == refreshID else { return }
            errorMessage = "无法读取知识库：\(error.localizedDescription)"
        }
    }

    func select(_ document: NoteDocument) {
        if selectedDocument?.id == document.id {
            selectedDocument = document
            return
        }
        guard flushSave() else { return }
        do {
            editorText = try knowledgeBase.read(document)
            loadedText = editorText
            selectedDocument = document
            defaults.set(document.relativePath, forKey: Keys.selectedPath)
            revisions = knowledgeBase.revisions(for: document)
            saveState = .saved(.now)
        } catch {
            errorMessage = "无法打开文稿：\(error.localizedDescription)"
        }
    }

    func editorDidChange() {
        guard editorText != loadedText, selectedDocument != nil else { return }
        saveState = .saving
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            _ = saveNow()
        }
    }

    @discardableResult
    func saveNow() -> Bool {
        guard let document = selectedDocument, editorText != loadedText else { return true }
        do {
            try knowledgeBase.write(editorText, to: document)
            loadedText = editorText
            saveState = .saved(.now)
            if let idx = documents.firstIndex(where: { $0.relativePath == document.relativePath }) {
                let newSize = (try? document.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? document.size
                documents[idx] = NoteDocument(
                    url: document.url,
                    relativePath: document.relativePath,
                    modifiedAt: .now,
                    size: newSize
                )
            }
            return true
        } catch {
            saveState = .failed(error.localizedDescription)
            errorMessage = "保存失败：\(error.localizedDescription)"
            return false
        }
    }

    func createNote() {
        guard let root = libraryURL else { chooseLibrary(); return }
        do {
            let folder = selectedDocument?.folder.isEmpty == false ? selectedDocument?.folder : nil
            let url = try knowledgeBase.createNote(root: root, folder: folder)
            Task {
                await refreshLibrary()
                if let document = documents.first(where: { $0.url == url }) { select(document) }
            }
        } catch {
            errorMessage = "新建文稿失败：\(error.localizedDescription)"
        }
    }

    func createFolder() {
        guard let root = libraryURL else { chooseLibrary(); return }
        do {
            _ = try knowledgeBase.createFolder(root: root)
            Task { await refreshLibrary() }
        } catch {
            errorMessage = "新建文件夹失败：\(error.localizedDescription)"
        }
    }

    func rename(_ document: NoteDocument, to name: String) {
        do {
            let wasSelected = selectedDocument?.id == document.id
            if wasSelected, !flushSave() { return }
            let destination = try knowledgeBase.rename(document, to: name)
            guard destination.standardizedFileURL != document.url.standardizedFileURL else { return }

            let newRelativePath = relativePath(for: destination)
            migrateDocumentState(
                from: document.relativePath,
                to: newRelativePath,
                updateSelection: wasSelected
            )
            do {
                try knowledgeBase.migrateRevisions(
                    from: document.relativePath,
                    to: newRelativePath
                )
            } catch {
                errorMessage = "文稿已重命名，但历史版本迁移失败：\(error.localizedDescription)"
            }
            if wasSelected {
                selectedDocument = nil
            }
            Task { await refreshLibrary(selecting: wasSelected ? newRelativePath : nil) }
        } catch {
            errorMessage = "重命名失败：\(error.localizedDescription)"
        }
    }

    func delete(_ document: NoteDocument) {
        do {
            if selectedDocument == document, !flushSave() { return }
            try knowledgeBase.trash(document)
            if selectedDocument == document {
                saveTask?.cancel()
                selectedDocument = nil
                editorText = ""
                loadedText = ""
            }
            chats[document.relativePath] = nil
            persistChats()
            Task { await refreshLibrary() }
        } catch {
            errorMessage = "移到废纸篓失败：\(error.localizedDescription)"
        }
    }

    func toggleFavorite(_ document: NoteDocument) {
        if favorites.contains(document.relativePath) {
            favorites.remove(document.relativePath)
        } else {
            favorites.insert(document.relativePath)
        }
        defaults.set(Array(favorites), forKey: Keys.favorites)
    }

    func performSearch() {
        searchTask?.cancel()
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        let documents = documents
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let results = await Task.detached(priority: .userInitiated) {
                KnowledgeBaseService().search(query: query, documents: documents)
            }.value
            guard !Task.isCancelled,
                  searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query
            else { return }
            searchResults = results
        }
    }

    func sendMessage(_ text: String) {
        guard let document = selectedDocument else { return }
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isGenerating else { return }
        let key = document.relativePath
        let userMessage = ChatMessage(role: .user, text: question)
        chats[key, default: []].append(userMessage)
        persistChats()
        isGenerating = true
        retrievalStatus = "正在搜索知识库…"

        let currentText = editorText
        let history = chats[key] ?? []
        let config = configuration
        let scope = retrievalScope
        let allDocuments = documents

        Task {
            let chunks = await Task.detached {
                KnowledgeBaseService().retrieve(
                    query: question,
                    documents: allDocuments,
                    currentDocument: document,
                    scope: scope
                )
            }.value
            retrievalStatus = "搜索了 \(Set(chunks.map(\.filePath)).count) 篇笔记，引用了 \(chunks.count) 个片段"
            do {
                let response = try await ai.answer(
                    question: question,
                    currentText: currentText,
                    history: history,
                    sources: chunks,
                    configuration: config
                )
                let (displayText, extractedEdit) = Self.extractEdit(from: response.text)
                chats[key, default: []].append(ChatMessage(
                    role: .assistant,
                    text: displayText,
                    sources: response.sources,
                    isGeneralKnowledge: response.usedGeneralKnowledge,
                    usage: response.usage,
                    cost: response.cost
                ))
                persistChats()
                if let editText = extractedEdit {
                    if selectedDocument?.relativePath == key {
                        editProposal = EditProposal(
                            documentPath: key,
                            original: currentText,
                            replacement: editText,
                            instruction: question
                        )
                    }
                }
                if provider == .deepSeek {
                    await refreshAccountBalance(force: true)
                }
            } catch {
                chats[key, default: []].append(ChatMessage(
                    role: .assistant,
                    text: "回答失败：\(error.localizedDescription)"
                ))
                persistChats()
            }
            isGenerating = false
        }
    }

    func clearCurrentChat() {
        guard let key = selectedDocument?.relativePath else { return }
        chats[key] = []
        persistChats()
    }

    func proposeEdit(instruction: String) {
        guard let documentPath = selectedDocument?.relativePath,
              !editorText.isEmpty,
              editProposal == nil else { return }
        let originalText = editorText
        isGenerating = true
        Task {
            do {
                let replacement = try await ai.proposeEdit(
                    instruction: instruction,
                    currentText: originalText,
                    configuration: configuration
                )
                if selectedDocument?.relativePath == documentPath {
                    editProposal = EditProposal(
                        documentPath: documentPath,
                        original: originalText,
                        replacement: replacement,
                        instruction: instruction
                    )
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isGenerating = false
        }
    }

    func applyProposal() {
        guard let proposal = editProposal, let document = selectedDocument else { return }
        guard proposal.canApply(
            to: document.relativePath,
            currentText: editorText
        ) else {
            errorMessage = "生成建议后文稿已经发生变化。为避免覆盖新内容，请重新生成修改建议。"
            return
        }
        do {
            _ = try knowledgeBase.createSnapshot(text: editorText, document: document)
            editorText = proposal.replacement
        } catch {
            errorMessage = "应用修改失败：\(error.localizedDescription)"
            return
        }
        saveNow()
        if case .saved = saveState {
            editProposal = nil
        }
        revisions = knowledgeBase.revisions(for: document)
    }

    func createManualSnapshot() {
        guard let document = selectedDocument else { return }
        do {
            _ = try knowledgeBase.createSnapshot(text: editorText, document: document)
            revisions = knowledgeBase.revisions(for: document)
        } catch {
            errorMessage = "创建版本失败：\(error.localizedDescription)"
        }
    }

    func restore(_ revision: Revision) {
        guard let document = selectedDocument else { return }
        do {
            _ = try knowledgeBase.createSnapshot(text: editorText, document: document)
            editorText = try String(contentsOf: revision.url, encoding: .utf8)
            saveNow()
            revisions = knowledgeBase.revisions(for: document)
        } catch {
            errorMessage = "恢复版本失败：\(error.localizedDescription)"
        }
    }

    func openSource(_ source: RetrievedChunk) {
        if let document = documents.first(where: { $0.relativePath == source.filePath }) {
            select(document)
        }
    }

    func revealInFinder(_ document: NoteDocument) {
        NSWorkspace.shared.activateFileViewerSelecting([document.url])
    }

    func toggleAssistant() {
        isAssistantVisible.toggle()
        defaults.set(isAssistantVisible, forKey: Keys.assistantVisible)
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
        defaults.set(isSidebarVisible, forKey: Keys.sidebarVisible)
    }

    private var configuration: AIConfiguration {
        AIConfiguration(
            apiKey: apiKey,
            endpoint: AIEndpointResolver.chatCompletionsURL(from: endpoint)
                ?? URL(string: "https://api.openai.com/v1/chat/completions")!,
            model: model,
            provider: provider
        )
    }

    private var excludedFolders: [String] {
        excludedFoldersText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    @discardableResult
    private func flushSave() -> Bool {
        saveTask?.cancel()
        return saveNow()
    }

    private func clearDocumentSelection() {
        selectedDocument = nil
        editorText = ""
        loadedText = ""
        revisions = []
        editProposal = nil
    }

    private func relativePath(for url: URL) -> String {
        guard let root = libraryURL?.standardizedFileURL else {
            return url.lastPathComponent
        }
        let path = url.standardizedFileURL.path
        return String(path.dropFirst(min(path.count, root.path.count + 1)))
    }

    private func migrateDocumentState(
        from oldPath: String,
        to newPath: String,
        updateSelection: Bool
    ) {
        if favorites.remove(oldPath) != nil {
            favorites.insert(newPath)
            defaults.set(Array(favorites), forKey: Keys.favorites)
        }
        if let messages = chats.removeValue(forKey: oldPath) {
            chats[newPath] = messages
            persistChats()
        }
        if updateSelection {
            defaults.set(newPath, forKey: Keys.selectedPath)
        }
    }

    private func persistChats() {
        guard let data = try? JSONEncoder().encode(chats) else { return }
        defaults.set(data, forKey: Keys.chats)
    }

    private static func loadChats(defaults: UserDefaults) -> [String: [ChatMessage]] {
        guard let data = defaults.data(forKey: Keys.chats),
              let value = try? JSONDecoder().decode([String: [ChatMessage]].self, from: data)
        else { return [:] }
        return value
    }

    private static func inferProvider(from endpoint: String?) -> AIProviderPreset {
        guard let endpoint else { return .openAI }
        if endpoint.contains("api.deepseek.com") { return .deepSeek }
        if endpoint.contains("api.openai.com") { return .openAI }
        return .custom
    }

    private static func extractEdit(from text: String) -> (display: String, edit: String?) {
        let marker = "```edit\n"
        let endMarker = "\n```"
        guard let start = text.range(of: marker) else { return (text, nil) }
        let after = text[start.upperBound...]
        guard let end = after.range(of: endMarker) else { return (text, nil) }
        let editContent = String(after[..<end.lowerBound])
        let suffix = after[end.upperBound...]
        var display = String(text[..<start.lowerBound]) + String(suffix)
        display = display.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if display.isEmpty { display = text }
        return (display, editContent.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))
    }

    private enum Keys {
        static let libraryPath = "libraryPath"
        static let selectedPath = "selectedPath"
        static let favorites = "favorites"
        static let chats = "chats"
        static let model = "model"
        static let endpoint = "endpoint"
        static let provider = "provider"
        static let excludedFolders = "excludedFolders"
        static let assistantVisible = "assistantVisible"
        static let sidebarVisible = "sidebarVisible"
        static let colorScheme = "colorScheme"
    }
}
