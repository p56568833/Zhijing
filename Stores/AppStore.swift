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
    var folders: [String] = []
    private(set) var folderGroups: [LibraryFolderGroup] = []
    private(set) var recentDocuments: [NoteDocument] = []
    private(set) var favoriteDocuments: [NoteDocument] = []
    var selectedDocument: NoteDocument?
    private(set) var editorText = ""
    private(set) var editorContentRevision = 0
    private(set) var editorNavigationRequest: EditorNavigationRequest?
    private(set) var editorSelection: EditorTextSelection?
    private(set) var documentWordCount = 0
    var isDocumentFindVisible = false
    var documentFindOptions = DocumentFindOptions()
    private(set) var documentFindResult = DocumentFindResult()
    private(set) var documentFindNavigationRequest: DocumentFindNavigationRequest?
    var selectionEditRequest: SelectionEditRequest?
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
    var externalConflict: ExternalFileConflict?
    private(set) var openDocumentPaths: [String] = []
    var isComparisonVisible = false
    private(set) var comparisonDocumentPath: String?
    private(set) var comparisonText = ""

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
    private let libraryWatcher = LibraryWatcher()
    private let documentExporter = DocumentExportService()
    private var generationTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var wordCountTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var externalRefreshTask: Task<Void, Never>?
    private var pendingLibraryChangeURLs: Set<URL> = []
    private var loadedText = ""
    private var documentByPath: [String: NoteDocument] = [:]
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

    var canCancelGeneration: Bool {
        generationTask != nil
    }

    var openDocuments: [NoteDocument] {
        openDocumentPaths.compactMap { path in
            documentByPath[path]
        }
    }

    var comparisonDocument: NoteDocument? {
        guard let comparisonDocumentPath else { return nil }
        return documentByPath[comparisonDocumentPath]
    }

    var comparisonCandidates: [NoteDocument] {
        documents.filter { $0.id != selectedDocument?.id }
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
        openDocumentPaths = defaults.stringArray(forKey: Keys.openDocumentPaths) ?? []
        isComparisonVisible = defaults.object(forKey: Keys.comparisonVisible) as? Bool ?? false
        comparisonDocumentPath = defaults.string(forKey: Keys.comparisonDocumentPath)
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
        panel.title = "选择知识库"
        panel.message = "知境会读取此文件夹中的 Markdown、纯文本与 SRT 字幕文件"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard flushSave() else { return }
        clearDocumentSelection()
        resetWorkspaceNavigation()
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
        guard NoteDocument.isSupportedFile(fileURL) else {
            errorMessage = "知境目前只能打开 Markdown、纯文本或 SRT 字幕文件。"
            return
        }

        let currentRoot = libraryURL?.standardizedFileURL
        let isInCurrentLibrary = currentRoot.map {
            fileURL.path == $0.path || fileURL.path.hasPrefix($0.path + "/")
        } ?? false
        let root: URL
        if isInCurrentLibrary, let currentRoot {
            root = currentRoot
        } else {
            root = fileURL.deletingLastPathComponent()
        }
        let relativePath = String(fileURL.path.dropFirst(min(fileURL.path.count, root.path.count + 1)))

        if !isInCurrentLibrary {
            guard flushSave() else { return }
            clearDocumentSelection()
            resetWorkspaceNavigation()
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
                let service = KnowledgeBaseService()
                return (
                    documents: try service.scan(
                        root: libraryURL,
                        excludedFolders: excluded
                    ),
                    folders: try service.scanFolders(
                        root: libraryURL,
                        excludedFolders: excluded
                    )
                )
            }.value
            guard libraryRefreshID == refreshID,
                  self.libraryURL?.standardizedFileURL == libraryURL.standardizedFileURL
            else { return }
            documents = scanned.documents
            folders = scanned.folders
            refreshDerivedLibraryState()
            reconcileOpenDocuments()
            reloadComparisonDocument()
            startWatchingLibrary()
            let targetPath = relativePath ?? selectedDocument?.relativePath
            if let targetPath, let target = documentByPath[targetPath] {
                select(target)
            } else {
                if selectedDocument != nil {
                    if externalConflict?.document.id != selectedDocument?.id {
                        saveTask?.cancel()
                        clearDocumentSelection()
                        errorMessage = "当前文稿已不在知识库中，可能被其他应用移动或删除。"
                    } else {
                        return
                    }
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
            replaceEditorText(try knowledgeBase.read(document))
            loadedText = editorText
            selectedDocument = document
            addOpenDocument(document)
            ensureComparisonDiffersFromSelection()
            defaults.set(document.relativePath, forKey: Keys.selectedPath)
            revisions = knowledgeBase.revisions(for: document)
            saveState = .saved(.now)
        } catch {
            errorMessage = "无法打开文稿：\(error.localizedDescription)"
        }
    }

    func editorDidChange(_ text: String) {
        guard selectedDocument != nil else { return }
        editorText = text
        scheduleWordCount(for: text)
        saveTask?.cancel()
        guard editorText != loadedText else {
            saveState = .saved(.now)
            return
        }
        if externalConflict?.document.id == selectedDocument?.id {
            saveState = .failed("等待处理外部修改")
        } else {
            scheduleAutosave()
        }
    }

    func editorSelectionDidChange(_ selection: EditorTextSelection?) {
        editorSelection = selection
    }

    func handleSelectionEditAction(_ action: AISelectionEditAction) {
        guard let selection = validEditorSelection() else {
            errorMessage = "请先在编辑器中选中要修改的文字。"
            return
        }
        if action == .custom {
            selectionEditRequest = SelectionEditRequest(selection: selection)
        } else if let instruction = action.instruction {
            proposeSelectionEdit(instruction: instruction, selection: selection)
        }
    }

    func requestCustomSelectionEdit() {
        handleSelectionEditAction(.custom)
    }

    func proposeSelectionEdit(
        instruction: String,
        selection: EditorTextSelection
    ) {
        guard let document = selectedDocument,
              selection.documentID == document.id,
              validEditorSelection(selection) != nil,
              !isGenerating else { return }
        let originalText = editorText
        let selectionLineRange = Self.lineRange(
            for: selection.range,
            in: originalText
        )
        let context = Self.surroundingContext(
            in: originalText,
            selection: selection.range
        )
        let query = "\(instruction)\n\(selection.text)"
        let documents = documents
        let config = configuration
        let service = knowledgeBase
        isGenerating = true
        retrievalStatus = "正在理解选区并判断所需上下文…"

        Task {
            let chunks = await Task.detached(priority: .userInitiated) {
                service.retrieve(
                    query: query,
                    documents: documents,
                    currentDocument: document,
                    scope: .library,
                    limit: 5
                )
            }.value
            retrievalStatus = chunks.isEmpty
                ? "未使用知识库资料"
                : "AI 已自行筛选 \(Set(chunks.map(\.filePath)).count) 篇相关资料"
            do {
                let application = try await ai.proposeSelectionEdit(
                    instruction: instruction,
                    currentText: originalText,
                    selectedText: selection.text,
                    surroundingContext: context,
                    sources: chunks,
                    configuration: config
                )
                let outsideEdits = application.edits.filter {
                    !Self.contains(selection.range, range: $0.range)
                }
                let reasons = outsideEdits.compactMap(\.reason)
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if selectedDocument?.relativePath == document.relativePath {
                    editProposal = EditProposal(
                        documentPath: document.relativePath,
                        original: originalText,
                        replacement: application.replacement,
                        instruction: instruction,
                        selectionLineRange: selectionLineRange,
                        selectionRange: selection.range,
                        outsideSelectionReason: reasons.isEmpty && !outsideEdits.isEmpty
                            ? "为保证上下文衔接，AI 建议同时调整这部分。"
                            : reasons.joined(separator: "；")
                    )
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isGenerating = false
        }
    }

    @discardableResult
    func saveNow(ignoringExternalConflict: Bool = false) -> Bool {
        guard let document = selectedDocument, editorText != loadedText else { return true }
        if !ignoringExternalConflict,
           externalConflict?.document.id == document.id {
            saveState = .failed("等待处理外部修改")
            return false
        }
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
                refreshDerivedLibraryState()
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

    func move(_ document: NoteDocument, toFolder folder: String) {
        guard let root = libraryURL, document.folder != folder else { return }
        do {
            let wasSelected = selectedDocument?.id == document.id
            if wasSelected, !flushSave() { return }
            let destination = try knowledgeBase.move(
                document,
                toFolder: folder,
                root: root
            )
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
                errorMessage = "文稿已移动，但历史版本迁移失败：\(error.localizedDescription)"
            }
            if wasSelected {
                clearDocumentSelection()
            }
            Task { await refreshLibrary(selecting: wasSelected ? newRelativePath : nil) }
        } catch {
            errorMessage = "移动文稿失败：\(error.localizedDescription)"
        }
    }

    func renameFolder(_ folder: String, to name: String) {
        guard let root = libraryURL, !folder.isEmpty else { return }
        let affectedDocuments = documents.filter {
            $0.folder == folder || $0.folder.hasPrefix(folder + "/")
        }
        let selectedPath = selectedDocument?.relativePath
        let selectedIsAffected = selectedPath.map {
            $0.hasPrefix(folder + "/")
        } ?? false

        do {
            if selectedIsAffected, !flushSave() { return }
            let destination = try knowledgeBase.renameFolder(
                root: root,
                relativePath: folder,
                to: name
            )
            let newFolder = relativePath(for: destination)
            guard newFolder != folder else { return }

            var migratedSelection: String?
            for document in affectedDocuments {
                let suffix = String(document.relativePath.dropFirst(folder.count))
                let newPath = newFolder + suffix
                let isSelected = document.relativePath == selectedPath
                migrateDocumentState(
                    from: document.relativePath,
                    to: newPath,
                    updateSelection: isSelected
                )
                try? knowledgeBase.migrateRevisions(
                    from: document.relativePath,
                    to: newPath
                )
                if isSelected {
                    migratedSelection = newPath
                }
            }
            if selectedIsAffected {
                clearDocumentSelection()
            }
            Task { await refreshLibrary(selecting: migratedSelection) }
        } catch {
            errorMessage = "重命名文件夹失败：\(error.localizedDescription)"
        }
    }

    func deleteFolder(_ folder: String) {
        guard let root = libraryURL, !folder.isEmpty else { return }
        let affectedPaths = documents
            .filter { $0.folder == folder || $0.folder.hasPrefix(folder + "/") }
            .map(\.relativePath)
        let selectedIsAffected = selectedDocument.map {
            affectedPaths.contains($0.relativePath)
        } ?? false

        do {
            if selectedIsAffected, !flushSave() { return }
            try knowledgeBase.trashFolder(root: root, relativePath: folder)
            favorites.subtract(affectedPaths)
            defaults.set(Array(favorites), forKey: Keys.favorites)
            for path in affectedPaths {
                chats[path] = nil
            }
            openDocumentPaths.removeAll { affectedPaths.contains($0) }
            persistOpenDocuments()
            if let comparisonDocumentPath,
               affectedPaths.contains(comparisonDocumentPath) {
                setComparisonDocument(nil)
            }
            persistChats()
            if selectedIsAffected {
                clearDocumentSelection()
            }
            Task { await refreshLibrary() }
        } catch {
            errorMessage = "删除文件夹失败：\(error.localizedDescription)"
        }
    }

    func delete(_ document: NoteDocument) {
        do {
            if selectedDocument == document, !flushSave() { return }
            try knowledgeBase.trash(document)
            if selectedDocument == document {
                saveTask?.cancel()
                selectedDocument = nil
                replaceEditorText("")
                loadedText = ""
            }
            openDocumentPaths.removeAll { $0 == document.relativePath }
            persistOpenDocuments()
            if comparisonDocumentPath == document.relativePath {
                setComparisonDocument(nil)
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
        refreshDerivedLibraryState()
    }

    func performSearch() {
        searchTask?.cancel()
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        let documents = documents
        let service = knowledgeBase
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let results = await Task.detached(priority: .userInitiated) {
                service.search(query: query, documents: documents)
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
        let currentSelection = validEditorSelection()
        let history = chats[key] ?? []
        let config = configuration
        let scope = retrievalScope
        let allDocuments = documents
        let service = knowledgeBase
        let assistantMessageID = UUID()

        generationTask = Task {
            let chunks = await Task.detached {
                service.retrieve(
                    query: question,
                    documents: allDocuments,
                    currentDocument: document,
                    scope: scope
                )
            }.value
            guard !Task.isCancelled else {
                isGenerating = false
                retrievalStatus = "已停止生成"
                return
            }
            retrievalStatus = "搜索了 \(Set(chunks.map(\.filePath)).count) 篇笔记，引用了 \(chunks.count) 个片段"
            let currentContext = Self.answerContext(
                question: question,
                document: document,
                text: currentText,
                selection: currentSelection
            )
            var streamedText = ""
            var didCreateAssistantMessage = false
            do {
                let stream = ai.answerStream(
                    question: question,
                    currentContext: currentContext,
                    history: history,
                    sources: chunks,
                    configuration: config
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
                        let (displayText, extractedEdit) = try AIEditPatchProcessor.extractFromChat(
                            response.text,
                            original: currentText
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
                    }
                }
                if provider == .deepSeek {
                    await refreshAccountBalance(force: true)
                }
            } catch is CancellationError {
                retrievalStatus = "已停止生成"
                if didCreateAssistantMessage {
                    updateAssistantMessage(
                        id: assistantMessageID,
                        documentPath: key,
                        text: streamedText.isEmpty ? "已停止生成。" : streamedText
                    )
                    persistChats()
                }
            } catch {
                chats[key, default: []].append(ChatMessage(
                    role: .assistant,
                    text: "回答失败：\(error.localizedDescription)"
                ))
                persistChats()
            }
            isGenerating = false
            generationTask = nil
        }
    }

    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
        retrievalStatus = "已停止生成"
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

    func applyProposal(replacement: String? = nil) {
        guard let proposal = editProposal, let document = selectedDocument else { return }
        guard proposal.canApply(
            to: document.relativePath,
            currentText: editorText
        ) else {
            errorMessage = "生成建议后文稿已经发生变化。为避免覆盖新内容，请重新生成修改建议。"
            return
        }
        let finalReplacement = replacement ?? proposal.replacement
        do {
            _ = try knowledgeBase.createSnapshot(text: editorText, document: document)
            replaceEditorText(finalReplacement)
            if proposal.selectionRange != nil {
                editorNavigationRequest = EditorNavigationRequest(
                    documentID: document.id,
                    selectionRange: Self.changedRange(
                        original: proposal.original,
                        replacement: finalReplacement
                    )
                )
            }
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

    func createManualSnapshot(name: String? = nil) {
        guard let document = selectedDocument else { return }
        do {
            _ = try knowledgeBase.createSnapshot(
                text: editorText,
                document: document,
                name: name
            )
            revisions = knowledgeBase.revisions(for: document)
        } catch {
            errorMessage = "创建版本失败：\(error.localizedDescription)"
        }
    }

    func revisionText(_ revision: Revision) -> String {
        (try? knowledgeBase.revisionText(revision)) ?? ""
    }

    func restore(_ revision: Revision) {
        guard let document = selectedDocument else { return }
        do {
            _ = try knowledgeBase.createSnapshot(
                text: editorText,
                document: document,
                name: "恢复前自动备份"
            )
            replaceEditorText(try String(contentsOf: revision.url, encoding: .utf8))
            saveNow()
            revisions = knowledgeBase.revisions(for: document)
        } catch {
            errorMessage = "恢复版本失败：\(error.localizedDescription)"
        }
    }

    func openSource(_ source: RetrievedChunk) {
        if let document = documents.first(where: { $0.relativePath == source.filePath }) {
            select(document)
            isPreviewMode = false
            editorNavigationRequest = EditorNavigationRequest(
                documentID: document.id,
                line: source.line
            )
        }
    }

    func revealInFinder(_ document: NoteDocument) {
        NSWorkspace.shared.activateFileViewerSelecting([document.url])
    }

    func closeDocumentTab(_ document: NoteDocument) {
        let closingSelectedDocument = selectedDocument?.id == document.id
        if closingSelectedDocument, !flushSave() { return }

        let closingIndex = openDocumentPaths.firstIndex(of: document.relativePath) ?? 0
        openDocumentPaths.removeAll { $0 == document.relativePath }
        persistOpenDocuments()

        if comparisonDocumentPath == document.relativePath {
            comparisonDocumentPath = nil
            comparisonText = ""
        }

        guard closingSelectedDocument else { return }
        let remaining = openDocuments
        if !remaining.isEmpty {
            let nextIndex = min(closingIndex, remaining.count - 1)
            selectedDocument = nil
            select(remaining[nextIndex])
        } else {
            clearDocumentSelection()
            isComparisonVisible = false
            defaults.set(false, forKey: Keys.comparisonVisible)
        }
    }

    func toggleComparison() {
        if isComparisonVisible {
            isComparisonVisible = false
            defaults.set(false, forKey: Keys.comparisonVisible)
            return
        }
        guard !comparisonCandidates.isEmpty else {
            errorMessage = "知识库里需要至少两篇文稿才能分屏对照。"
            return
        }
        if comparisonDocument == nil || comparisonDocument?.id == selectedDocument?.id {
            let preferred = openDocuments.first {
                $0.id != selectedDocument?.id
            } ?? comparisonCandidates[0]
            setComparisonDocument(preferred.relativePath)
        } else {
            reloadComparisonDocument()
        }
        isComparisonVisible = true
        defaults.set(true, forKey: Keys.comparisonVisible)
    }

    func setComparisonDocument(_ relativePath: String?) {
        guard let relativePath,
              relativePath != selectedDocument?.relativePath,
              documents.contains(where: { $0.relativePath == relativePath }) else {
            comparisonDocumentPath = nil
            comparisonText = ""
            defaults.removeObject(forKey: Keys.comparisonDocumentPath)
            return
        }
        comparisonDocumentPath = relativePath
        defaults.set(relativePath, forKey: Keys.comparisonDocumentPath)
        reloadComparisonDocument()
    }

    func exportCurrentDocument(as format: DocumentExportFormat) {
        guard let document = selectedDocument, flushSave() else { return }
        do {
            _ = try documentExporter.presentExport(
                title: document.title,
                markdown: editorText,
                format: format
            )
        } catch {
            errorMessage = "导出 \(format.displayName) 失败：\(error.localizedDescription)"
        }
    }

    func toggleAssistant() {
        isAssistantVisible.toggle()
        defaults.set(isAssistantVisible, forKey: Keys.assistantVisible)
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
        defaults.set(isSidebarVisible, forKey: Keys.sidebarVisible)
    }

    func showDocumentFind() {
        guard selectedDocument != nil else { return }
        isPreviewMode = false
        isDocumentFindVisible = true
    }

    func hideDocumentFind() {
        isDocumentFindVisible = false
        documentFindOptions.query = ""
        documentFindResult = DocumentFindResult()
        documentFindNavigationRequest = nil
    }

    func findNext() {
        guard selectedDocument != nil else { return }
        isPreviewMode = false
        isDocumentFindVisible = true
        documentFindNavigationRequest = DocumentFindNavigationRequest(
            direction: .next
        )
    }

    func findPrevious() {
        guard selectedDocument != nil else { return }
        isPreviewMode = false
        isDocumentFindVisible = true
        documentFindNavigationRequest = DocumentFindNavigationRequest(
            direction: .previous
        )
    }

    func handleDocumentFindCommand(_ command: DocumentFindCommand) {
        switch command {
        case .show:
            showDocumentFind()
        case .previous:
            findPrevious()
        case .next:
            findNext()
        }
    }

    func updateDocumentFindResult(_ result: DocumentFindResult) {
        guard documentFindResult != result else { return }
        documentFindResult = result
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
        guard let index = chats[documentPath]?.firstIndex(where: { $0.id == id }) else {
            return
        }
        let old = chats[documentPath]?[index]
        chats[documentPath]?[index] = ChatMessage(
            id: id,
            role: .assistant,
            text: text,
            createdAt: old?.createdAt ?? .now,
            sources: sources ?? old?.sources ?? [],
            isGeneralKnowledge: isGeneralKnowledge ?? old?.isGeneralKnowledge ?? false,
            usage: usage ?? old?.usage,
            cost: cost ?? old?.cost
        )
    }

    private static func answerContext(
        question: String,
        document: NoteDocument,
        text: String,
        selection: EditorTextSelection?
    ) -> String {
        let limit = 12_000
        guard text.utf16.count > limit else { return text }

        let nsText = text as NSString
        var sections: [String] = []
        sections.append("文稿：\(document.relativePath)")
        sections.append("[开头]\n\(String(text.prefix(2_200)))")

        if let selection, !selection.isEmpty {
            sections.append("[当前选区]\n\(selection.text)")
        }

        let queryTerms = Set(SearchTokenization.tokenize(question))
        let lines = text.components(separatedBy: .newlines)
        let scoredLines = lines.enumerated().compactMap { index, line -> (Int, Double)? in
            let terms = Set(SearchTokenization.tokenize(line))
            let score = Double(queryTerms.intersection(terms).count)
            return score > 0 ? (index, score) : nil
        }
        .sorted {
            if $0.1 == $1.1 { return $0.0 < $1.0 }
            return $0.1 > $1.1
        }
        .prefix(8)

        var usedRanges: [Range<Int>] = []
        for (index, _) in scoredLines {
            let range = max(0, index - 2)..<min(lines.count, index + 3)
            guard !usedRanges.contains(where: { rangesOverlap($0, range) }) else {
                continue
            }
            usedRanges.append(range)
            let snippet = lines[range].joined(separator: "\n")
            sections.append("[相关片段 · 第 \(range.lowerBound + 1) 行]\n\(snippet)")
        }

        let tailStart = max(0, nsText.length - 1_600)
        let tailRange = nsText.rangeOfComposedCharacterSequences(
            for: NSRange(location: tailStart, length: nsText.length - tailStart)
        )
        sections.append("[结尾]\n\(nsText.substring(with: tailRange))")

        return sections.joined(separator: "\n\n---\n\n")
    }

    private static func rangesOverlap(_ lhs: Range<Int>, _ rhs: Range<Int>) -> Bool {
        lhs.lowerBound < rhs.upperBound && rhs.lowerBound < lhs.upperBound
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

    func keepLocalVersionAfterConflict() {
        guard let conflict = externalConflict,
              selectedDocument?.id == conflict.document.id else { return }
        do {
            if let diskText = conflict.diskText {
                _ = try knowledgeBase.createSnapshot(
                    text: diskText,
                    document: conflict.document,
                    name: "外部修改（冲突备份）"
                )
            }
            try knowledgeBase.write(editorText, to: conflict.document)
            loadedText = editorText
            externalConflict = nil
            saveState = .saved(.now)
            revisions = knowledgeBase.revisions(for: conflict.document)
            Task { await refreshLibrary(selecting: conflict.document.relativePath) }
        } catch {
            errorMessage = "保留本地版本失败：\(error.localizedDescription)"
        }
    }

    func loadExternalVersionAfterConflict() {
        guard let conflict = externalConflict,
              let diskText = conflict.diskText,
              selectedDocument?.id == conflict.document.id else { return }
        do {
            _ = try knowledgeBase.createSnapshot(
                text: editorText,
                document: conflict.document,
                name: "冲突前的本地版本"
            )
            replaceEditorText(diskText)
            loadedText = diskText
            externalConflict = nil
            saveState = .saved(.now)
            revisions = knowledgeBase.revisions(for: conflict.document)
            Task { await refreshLibrary(selecting: conflict.document.relativePath) }
        } catch {
            errorMessage = "载入外部版本失败：\(error.localizedDescription)"
        }
    }

    func discardLocalVersionAfterExternalRemoval() {
        guard externalConflict?.fileWasRemoved == true else { return }
        externalConflict = nil
        clearDocumentSelection()
        Task { await refreshLibrary() }
    }

    @discardableResult
    private func flushSave() -> Bool {
        saveTask?.cancel()
        return saveNow()
    }

    private func refreshDerivedLibraryState() {
        documentByPath = Dictionary(
            uniqueKeysWithValues: documents.map { ($0.relativePath, $0) }
        )
        recentDocuments = Array(
            documents.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(8)
        )
        favoriteDocuments = documents.filter {
            favorites.contains($0.relativePath)
        }

        let groups = Dictionary(grouping: documents, by: \.folder)
        let folderNames = Set(folders)
            .union(groups.keys)
            .union([""])
        folderGroups = folderNames.map {
            LibraryFolderGroup(name: $0, documents: groups[$0] ?? [])
        }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func clearDocumentSelection() {
        selectedDocument = nil
        editorSelection = nil
        hideDocumentFind()
        wordCountTask?.cancel()
        documentWordCount = 0
        replaceEditorText("")
        loadedText = ""
        revisions = []
        editProposal = nil
        externalConflict = nil
    }

    private func scheduleAutosave() {
        saveState = .saving
        guard let document = selectedDocument else { return }
        let text = editorText
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            await autosave(text: text, document: document)
        }
    }

    private func autosave(text: String, document: NoteDocument) async {
        guard selectedDocument?.id == document.id else { return }
        guard editorText == text else { return }
        if externalConflict?.document.id == document.id {
            saveState = .failed("等待处理外部修改")
            return
        }

        do {
            let newSize = try await writeInBackground(text, to: document)
            guard selectedDocument?.id == document.id, editorText == text else { return }
            loadedText = text
            saveState = .saved(.now)
            if let idx = documents.firstIndex(where: { $0.relativePath == document.relativePath }) {
                documents[idx] = NoteDocument(
                    url: document.url,
                    relativePath: document.relativePath,
                    modifiedAt: .now,
                    size: newSize
                )
                refreshDerivedLibraryState()
            }
        } catch {
            guard selectedDocument?.id == document.id, editorText == text else { return }
            saveState = .failed(error.localizedDescription)
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private func writeInBackground(
        _ text: String,
        to document: NoteDocument
    ) async throws -> Int {
        let service = knowledgeBase
        return try await Task.detached(priority: .utility) {
            try service.write(text, to: document)
            return (try? document.url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                ?? document.size
        }.value
    }

    private func scheduleWordCount(
        for text: String,
        delay: Duration = .milliseconds(280)
    ) {
        wordCountTask?.cancel()
        wordCountTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let count = await Task.detached(priority: .utility) {
                DocumentMetrics(markdown: text).count
            }.value
            guard !Task.isCancelled, editorText == text else { return }
            documentWordCount = count
        }
    }

    private func startWatchingLibrary() {
        guard let libraryURL else {
            libraryWatcher.stop()
            return
        }
        libraryWatcher.start(
            root: libraryURL,
            excludedFolders: excludedFolders
        ) { [weak self] changedURLs in
            Task { @MainActor [weak self] in
                self?.libraryDidChange(changedURLs)
            }
        }
    }

    private func libraryDidChange(_ changedURLs: [URL]) {
        pendingLibraryChangeURLs.formUnion(changedURLs.map(\.standardizedFileURL))
        externalRefreshTask?.cancel()
        externalRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let changedURLs = pendingLibraryChangeURLs
            pendingLibraryChangeURLs.removeAll()
            await reconcileExternalChanges(changedURLs: changedURLs)
        }
    }

    private func reconcileExternalChanges(changedURLs: Set<URL>) async {
        guard let document = selectedDocument else {
            await refreshLibrary()
            return
        }

        saveTask?.cancel()
        if shouldCheckSelectedDocument(document, changedURLs: changedURLs) {
            let fileExists = FileManager.default.fileExists(atPath: document.url.path)
            let diskText: String?
            do {
                diskText = fileExists ? try knowledgeBase.read(document) : nil
            } catch {
                errorMessage = "无法读取外部修改：\(error.localizedDescription)"
                return
            }

            switch ExternalFileReconciler.evaluate(
                loadedText: loadedText,
                editorText: editorText,
                diskText: diskText
            ) {
            case .unchanged:
                break
            case .localChangesOnly:
                scheduleAutosave()
            case .synchronized(let text):
                loadedText = text
                saveState = .saved(.now)
            case .reloadFromDisk(let text):
                replaceEditorText(text)
                loadedText = text
                saveState = .saved(.now)
            case .conflict(let text):
                externalConflict = ExternalFileConflict(
                    document: document,
                    localText: editorText,
                    diskText: text,
                    detectedAt: .now
                )
                saveState = .failed("检测到外部修改")
            case .removedCleanly:
                break
            case .removedWithLocalChanges:
                externalConflict = ExternalFileConflict(
                    document: document,
                    localText: editorText,
                    diskText: nil,
                    detectedAt: .now
                )
                saveState = .failed("文稿已被外部移除")
            }
        }

        await refreshLibrary(selecting: document.relativePath)
    }

    private func shouldCheckSelectedDocument(
        _ document: NoteDocument,
        changedURLs: Set<URL>
    ) -> Bool {
        guard !changedURLs.isEmpty else { return true }
        let documentPath = document.url.standardizedFileURL.path
        let parentPath = document.url.deletingLastPathComponent().standardizedFileURL.path
        return changedURLs.contains { url in
            let path = url.standardizedFileURL.path
            return path == documentPath || path == parentPath
        }
    }

    private func replaceEditorText(_ text: String) {
        editorText = text
        editorContentRevision &+= 1
        scheduleWordCount(for: text, delay: .zero)
    }

    private func validEditorSelection(
        _ candidate: EditorTextSelection? = nil
    ) -> EditorTextSelection? {
        guard let selection = candidate ?? editorSelection,
              let document = selectedDocument,
              selection.documentID == document.id,
              selection.range.length > 0 else { return nil }
        let source = editorText as NSString
        guard NSMaxRange(selection.range) <= source.length,
              source.substring(with: selection.range) == selection.text else {
            return nil
        }
        return selection
    }

    private static func contains(_ container: NSRange, range: NSRange) -> Bool {
        range.location >= container.location &&
            NSMaxRange(range) <= NSMaxRange(container)
    }

    private static func lineRange(
        for range: NSRange,
        in text: String
    ) -> Range<Int> {
        let source = text as NSString
        let start = min(range.location, source.length)
        let end = min(max(start, NSMaxRange(range) - 1), max(0, source.length - 1))
        let startLine = source.substring(to: start)
            .reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        let endLine = source.substring(to: min(source.length, end + 1))
            .reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        return startLine..<max(startLine + 1, endLine + 1)
    }

    private static func surroundingContext(
        in text: String,
        selection: NSRange
    ) -> String {
        let source = text as NSString
        let padding = 2_400
        let lower = max(0, selection.location - padding)
        let upper = min(source.length, NSMaxRange(selection) + padding)
        let safeRange = source.rangeOfComposedCharacterSequences(
            for: NSRange(location: lower, length: upper - lower)
        )
        return source.substring(with: safeRange)
    }

    private static func changedRange(
        original: String,
        replacement: String
    ) -> NSRange {
        let old = original as NSString
        let new = replacement as NSString
        let sharedLimit = min(old.length, new.length)
        var prefix = 0
        while prefix < sharedLimit,
              old.character(at: prefix) == new.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.length - prefix,
              suffix < new.length - prefix,
              old.character(at: old.length - suffix - 1) ==
                new.character(at: new.length - suffix - 1) {
            suffix += 1
        }
        return NSRange(
            location: prefix,
            length: max(0, new.length - prefix - suffix)
        )
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
        if let index = openDocumentPaths.firstIndex(of: oldPath) {
            openDocumentPaths[index] = newPath
            persistOpenDocuments()
        }
        if comparisonDocumentPath == oldPath {
            comparisonDocumentPath = newPath
            defaults.set(newPath, forKey: Keys.comparisonDocumentPath)
        }
        if updateSelection {
            defaults.set(newPath, forKey: Keys.selectedPath)
        }
    }

    private func addOpenDocument(_ document: NoteDocument) {
        guard !openDocumentPaths.contains(document.relativePath) else { return }
        openDocumentPaths.append(document.relativePath)
        persistOpenDocuments()
    }

    private func reconcileOpenDocuments() {
        let validPaths = Set(documents.map(\.relativePath))
        var seen: Set<String> = []
        openDocumentPaths = openDocumentPaths.filter { path in
            validPaths.contains(path) && seen.insert(path).inserted
        }
        persistOpenDocuments()
    }

    private func persistOpenDocuments() {
        defaults.set(openDocumentPaths, forKey: Keys.openDocumentPaths)
    }

    private func resetWorkspaceNavigation() {
        openDocumentPaths = []
        comparisonDocumentPath = nil
        comparisonText = ""
        isComparisonVisible = false
        defaults.removeObject(forKey: Keys.openDocumentPaths)
        defaults.removeObject(forKey: Keys.comparisonDocumentPath)
        defaults.set(false, forKey: Keys.comparisonVisible)
    }

    private func ensureComparisonDiffersFromSelection() {
        guard comparisonDocumentPath == selectedDocument?.relativePath else {
            reloadComparisonDocument()
            return
        }
        if let alternative = openDocuments.first(where: {
            $0.id != selectedDocument?.id
        }) ?? comparisonCandidates.first {
            setComparisonDocument(alternative.relativePath)
        } else {
            setComparisonDocument(nil)
            isComparisonVisible = false
            defaults.set(false, forKey: Keys.comparisonVisible)
        }
    }

    private func reloadComparisonDocument() {
        guard let document = comparisonDocument else {
            comparisonText = ""
            if comparisonDocumentPath != nil {
                comparisonDocumentPath = nil
                defaults.removeObject(forKey: Keys.comparisonDocumentPath)
            }
            return
        }
        do {
            comparisonText = try knowledgeBase.read(document)
        } catch {
            comparisonText = ""
            errorMessage = "无法打开对照文稿：\(error.localizedDescription)"
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
        static let openDocumentPaths = "openDocumentPaths"
        static let comparisonVisible = "comparisonVisible"
        static let comparisonDocumentPath = "comparisonDocumentPath"
    }
}
