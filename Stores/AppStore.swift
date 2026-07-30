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
    private(set) var libraryTree: [LibraryTreeItem] = []
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
    private(set) var annotationComposerRequest: AnnotationComposerRequest?
    private(set) var annotations: [String: [TextAnnotation]] = [:]
    var searchQuery = ""
    var searchResults: [SearchHit] = []
    var favorites: Set<String> = []
    var saveState: SaveState = .idle
    var isIndexing = false
    var isAssistantVisible = true
    var isSidebarVisible = true
    var isAnnotationRailVisible = true
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
    private(set) var externalDocuments: [NoteDocument] = []
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
            do {
                try LocalSecretStore.save(apiKey, account: "openai-api-key")
            } catch {
                errorMessage = "API Key 无法保存到本地配置：\(error.localizedDescription)"
            }
        }
    }

    private let defaults: UserDefaults
    private let knowledgeBase = KnowledgeBaseService()
    private let ai = AIService()
    private let libraryWatcher = LibraryWatcher()
    private let documentExporter = DocumentExportService()
    private let documentSession = DocumentSessionController()
    private let chatPersistence = ChatPersistenceService()
    private let annotationPersistence = AnnotationPersistenceService()
    @ObservationIgnored
    private var generationTask: Task<Void, Never>?
    @ObservationIgnored
    private var generationID: UUID?
    @ObservationIgnored
    private var wordCountTask: Task<Void, Never>?
    @ObservationIgnored
    private var searchTask: Task<Void, Never>?
    @ObservationIgnored
    private var externalRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var pendingLibraryChangeURLs: Set<URL> = []
    @ObservationIgnored
    private var snapshottedProposalIDs: Set<UUID> = []
    @ObservationIgnored
    private var documentByPath: [String: NoteDocument] = [:]
    @ObservationIgnored
    private var lastBalanceRefresh: Date?
    @ObservationIgnored
    private var libraryRefreshID = UUID()
    @ObservationIgnored
    private var loadedAnnotationRootPath: String?
    @ObservationIgnored
    private var annotationPersistenceBlockedRoots: Set<String> = []

    var currentMessages: [ChatMessage] {
        guard let key = selectedDocument?.persistenceKey else { return [] }
        return chats[key] ?? []
    }

    var currentAnnotations: [TextAnnotation] {
        guard let key = selectedDocument?.persistenceKey else { return [] }
        return annotations[key] ?? []
    }

    var currentResolvedAnnotations: [ResolvedTextAnnotation] {
        currentAnnotations.compactMap {
            TextAnnotationAnchorResolver.resolve($0, in: editorText)
        }
    }

    var currentAnnotationDisplayItems: [TextAnnotationDisplayItem] {
        currentAnnotations.map { annotation in
            TextAnnotationDisplayItem(
                annotation: annotation,
                range: TextAnnotationAnchorResolver.resolve(
                    annotation,
                    in: editorText
                )?.range
            )
        }.sorted { lhs, rhs in
            switch (lhs.range, rhs.range) {
            case let (.some(left), .some(right)):
                return left.location < right.location
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.annotation.createdAt < rhs.annotation.createdAt
            }
        }
    }

    var latestUsage: AIUsage? {
        currentMessages.reversed().compactMap(\.usage).first
    }

    var currentConversationCost: AIUsageCost? {
        let costs = currentMessages.compactMap(\.cost)
        guard let currency = costs.first?.currency,
              costs.allSatisfy({ $0.currency == currency }) else { return nil }
        return AIUsageCost(
            amount: costs.reduce(0) { $0 + $1.amount },
            currency: currency
        )
    }

    var canCancelGeneration: Bool {
        generationTask != nil
    }

    var openDocuments: [NoteDocument] {
        let libraryDocuments = openDocumentPaths.compactMap { path in
            documentByPath[path]
        }
        return libraryDocuments + externalDocuments.filter { external in
            !libraryDocuments.contains(where: { $0.id == external.id })
        }
    }

    var selectedDocumentLocationLabel: String? {
        guard let document = selectedDocument else { return nil }
        if isLibraryDocument(document) {
            return document.folder.isEmpty ? "知识库根目录" : document.folder
        }
        let parent = document.url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? "外部文稿" : "外部文稿 · \(parent)"
    }

    var comparisonDocument: NoteDocument? {
        guard let comparisonDocumentPath else { return nil }
        return documentByPath[comparisonDocumentPath]
    }

    var comparisonCandidates: [NoteDocument] {
        documents.filter { $0.id != selectedDocument?.id }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        provider = AIProviderPreset(
            rawValue: defaults.string(forKey: Keys.provider) ?? ""
        ) ?? Self.inferProvider(from: defaults.string(forKey: Keys.endpoint))
        model = defaults.string(forKey: Keys.model) ?? "gpt-4.1-mini"
        endpoint = defaults.string(forKey: Keys.endpoint) ?? "https://api.openai.com/v1"
        excludedFoldersText = defaults.string(forKey: Keys.excludedFolders) ?? ".git, node_modules"
        apiKey = LocalSecretStore.read(account: "openai-api-key")
        favorites = Set(defaults.stringArray(forKey: Keys.favorites) ?? [])
        let legacyChats = defaults.data(forKey: Keys.chats)
        do {
            chats = try chatPersistence.loadStrict(legacyData: legacyChats)
        } catch {
            chats = [:]
            errorMessage = "对话记录无法读取，已停止覆盖原文件：\(error.localizedDescription)"
        }
        do {
            annotations = try annotationPersistence.loadStrict()
        } catch {
            annotations = [:]
            if errorMessage == nil {
                errorMessage = "批注缓存无法读取，已停止覆盖原文件：\(error.localizedDescription)"
            }
        }
        if legacyChats != nil {
            do {
                try chatPersistence.saveSynchronously(chats)
                defaults.removeObject(forKey: Keys.chats)
            } catch {
                errorMessage = "迁移对话记录失败：\(error.localizedDescription)"
            }
        }
        isAssistantVisible = defaults.object(forKey: Keys.assistantVisible) as? Bool ?? true
        isSidebarVisible = defaults.object(forKey: Keys.sidebarVisible) as? Bool ?? true
        isAnnotationRailVisible = defaults.object(
            forKey: Keys.annotationRailVisible
        ) as? Bool ?? true
        colorScheme = AppColorScheme(rawValue: defaults.string(forKey: Keys.colorScheme) ?? "") ?? .system
        openDocumentPaths = defaults.stringArray(forKey: Keys.openDocumentPaths) ?? []
        externalDocuments = (defaults.stringArray(forKey: Keys.externalDocumentPaths) ?? [])
            .compactMap { Self.makeExternalDocument(at: URL(filePath: $0)) }
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
        transitionToLibrary(url)
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
            let configuration = try resolvedConfiguration()
            try await ai.testConnection(configuration: configuration)
            guard configurationMatchesCurrent(configuration) else { return }
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
        let requestedKey = apiKey
        do {
            let balances = try await ai.fetchDeepSeekBalance(apiKey: requestedKey)
            guard provider == .deepSeek, apiKey == requestedKey else { return }
            accountBalances = balances
            lastBalanceRefresh = .now
        } catch {
            guard provider == .deepSeek, apiKey == requestedKey else { return }
            balanceError = error.localizedDescription
        }
    }

    func openDocuments(at urls: [URL]) {
        guard let request = DocumentOpenRequestResolver.resolve(
            urls: urls,
            currentLibrary: libraryURL
        ) else {
            errorMessage = "知境目前只能打开 Markdown、纯文本或 SRT 字幕文件。"
            return
        }

        let root = request.root
        let isInCurrentLibrary = libraryURL?.standardizedFileURL == root
        if !isInCurrentLibrary {
            guard flushSave() else { return }
            transitionToLibrary(root)
        }

        let externalDocuments = request.externalURLs.compactMap {
            Self.makeExternalDocument(at: $0)
        }
        for document in externalDocuments {
            addOpenDocument(document)
        }

        let firstIsExternal = externalDocuments.contains {
            $0.id == request.firstURL.standardizedFileURL.path
        }
        if firstIsExternal,
           let first = externalDocuments.first(where: {
               $0.id == request.firstURL.standardizedFileURL.path
           }) {
            select(first)
        }

        Task {
            if !request.relativePaths.isEmpty || !isInCurrentLibrary {
                await refreshLibrary(
                    selecting: firstIsExternal ? nil : request.relativePaths.first,
                    opening: request.relativePaths
                )
            }
        }
    }

    func refreshLibrary(
        selecting relativePath: String? = nil,
        opening relativePaths: [String] = []
    ) async {
        guard let libraryURL else { return }
        loadPortableAnnotationsIfNeeded(at: libraryURL)
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
                return try service.scanLibrary(
                    root: libraryURL,
                    excludedFolders: excluded
                )
            }.value
            guard libraryRefreshID == refreshID,
                  self.libraryURL?.standardizedFileURL == libraryURL.standardizedFileURL
            else { return }
            documents = scanned.documents
            folders = scanned.folders
            migrateExternalDocumentsIntoLibrary()
            refreshDerivedLibraryState()
            reconcileMovedAnnotationDocuments(in: libraryURL)
            if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                performSearch()
            }
            let service = knowledgeBase
            let indexedDocuments = scanned.documents
            Task.detached(priority: .utility) {
                service.prepareSearchIndex(documents: indexedDocuments)
            }
            reconcileOpenDocuments()
            reloadComparisonDocument()
            startWatchingLibrary()
            let selectedLibraryPath = selectedDocument.flatMap { selected in
                documents.first(where: { $0.id == selected.id })?.relativePath
            }
            let targetPath = relativePath ?? selectedLibraryPath
            if let targetPath, let target = documentByPath[targetPath] {
                select(target)
            } else if let selectedDocument {
                if externalDocuments.contains(where: { $0.id == selectedDocument.id }) {
                    // Keep an external tab selected while the library refreshes.
                } else {
                    if externalConflict?.document.id != selectedDocument.id {
                        documentSession.cancelAutosave()
                        clearDocumentSelection()
                        errorMessage = "当前文稿已不在知识库中，可能被其他应用移动或删除。"
                    } else {
                        return
                    }
                }
            } else {
                if let first = documents.first {
                    select(first)
                } else {
                    defaults.removeObject(forKey: Keys.selectedPath)
                    saveState = .idle
                }
            }
            for path in relativePaths where path != selectedDocument?.relativePath {
                if let document = documentByPath[path] {
                    addOpenDocument(document)
                }
            }
        } catch {
            guard libraryRefreshID == refreshID else { return }
            errorMessage = "无法读取知识库：\(error.localizedDescription)"
        }
    }

    func select(_ document: NoteDocument) {
        if selectedDocument?.id == document.id {
            selectedDocument = documentByPath[document.relativePath]
                ?? externalDocuments.first(where: { $0.id == document.id })
                ?? document
            return
        }
        guard flushSave() else { return }
        if isGenerating {
            cancelGeneration()
        }
        annotationComposerRequest = nil
        editorSelection = nil
        do {
            loadPortableAnnotations(for: document)
            replaceEditorText(
                try knowledgeBase.read(document),
                reanchoringAnnotations: false
            )
            documentSession.loadedText = editorText
            selectedDocument = document
            addOpenDocument(document)
            ensureComparisonDiffersFromSelection()
            if isLibraryDocument(document) {
                defaults.set(document.relativePath, forKey: Keys.selectedPath)
            }
            revisions = knowledgeBase.revisions(for: document)
            saveState = .saved(.now)
        } catch {
            errorMessage = "无法打开文稿：\(error.localizedDescription)"
        }
    }

    func editorDidChange(
        _ text: String,
        mutation: EditorTextMutation? = nil
    ) {
        guard selectedDocument != nil else { return }
        let oldText = editorText
        let annotationsChanged = reanchorCurrentAnnotations(
            from: oldText,
            to: text,
            mutation: mutation
        )
        editorText = text
        scheduleWordCount(for: text)
        documentSession.cancelAutosave()
        guard editorText != documentSession.loadedText else {
            if annotationsChanged {
                persistAnnotations(for: selectedDocument)
            }
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

    func requestAnnotationComposer() {
        guard !isPreviewMode, let selection = validEditorSelection() else {
            NSSound.beep()
            return
        }
        beginAnnotation(for: selection)
    }

    func beginAnnotation(for selection: EditorTextSelection) {
        guard !isPreviewMode,
              validEditorSelection(selection) != nil else {
            NSSound.beep()
            return
        }
        annotationComposerRequest = AnnotationComposerRequest(
            selection: selection
        )
        setAnnotationRailVisible(true)
    }

    func cancelAnnotationComposer() {
        annotationComposerRequest = nil
    }

    func addAnnotation(
        text: String,
        selection: EditorTextSelection
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let document = selectedDocument,
              let validSelection = validEditorSelection(selection),
              let anchor = TextAnnotationAnchorResolver.makeAnchor(
                  selection: validSelection,
                  in: editorText
              ) else { return }
        annotations[document.persistenceKey, default: []].append(
            TextAnnotation(anchor: anchor, text: value)
        )
        annotationComposerRequest = nil
        persistAnnotations(for: document)
    }

    func updateAnnotation(id: UUID, text: String) {
        guard let key = selectedDocument?.persistenceKey,
              let index = annotations[key]?.firstIndex(where: { $0.id == id })
        else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        annotations[key]?[index].text = value
        annotations[key]?[index].modifiedAt = .now
        persistAnnotations(for: selectedDocument)
    }

    func deleteAnnotation(id: UUID) {
        guard let key = selectedDocument?.persistenceKey else { return }
        annotations[key]?.removeAll { $0.id == id }
        if annotations[key]?.isEmpty == true {
            annotations[key] = nil
        }
        persistAnnotations(for: selectedDocument)
    }

    func toggleAnnotationResolution(id: UUID) {
        guard let key = selectedDocument?.persistenceKey,
              let index = annotations[key]?.firstIndex(where: { $0.id == id })
        else { return }
        guard var annotation = annotations[key]?[index] else { return }
        annotation.resolvedAt = annotation.isResolved ? nil : .now
        annotation.modifiedAt = .now
        annotations[key]?[index] = annotation
        persistAnnotations(for: selectedDocument)
    }

    func relinkAnnotation(id: UUID) {
        guard let key = selectedDocument?.persistenceKey,
              let index = annotations[key]?.firstIndex(where: { $0.id == id }),
              let selection = validEditorSelection(),
              let anchor = TextAnnotationAnchorResolver.makeAnchor(
                  selection: selection,
                  in: editorText
              ) else {
            NSSound.beep()
            return
        }
        annotations[key]?[index].anchor = anchor
        annotations[key]?[index].modifiedAt = .now
        persistAnnotations(for: selectedDocument)
    }

    func revealAnnotation(_ id: UUID) {
        guard let document = selectedDocument,
              let item = currentAnnotationDisplayItems.first(where: { $0.id == id }),
              let range = item.range else { return }
        isPreviewMode = false
        editorNavigationRequest = EditorNavigationRequest(
            documentID: document.id,
            selectionRange: range
        )
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
        let annotationContext = Self.annotationContext(
            annotations: currentAnnotations,
            in: originalText
        )
        let query = "\(instruction)\n\(selection.text)"
        let documents = documents
        let config: AIConfiguration
        do {
            config = try resolvedConfiguration()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let service = knowledgeBase
        guard let generationID = beginGeneration() else { return }
        retrievalStatus = "正在理解选区并判断所需上下文…"

        generationTask = Task {
            defer { finishGeneration(generationID) }
            let chunks = await Task.detached(priority: .userInitiated) {
                service.retrieve(
                    query: query,
                    documents: documents,
                    currentDocument: document,
                    scope: .library,
                    limit: 5
                )
            }.value
            guard !Task.isCancelled, self.generationID == generationID else { return }
            retrievalStatus = chunks.isEmpty
                ? "未使用知识库资料"
                : "AI 已自行筛选 \(Set(chunks.map(\.filePath)).count) 篇相关资料"
            do {
                let application = try await ai.proposeSelectionEdit(
                    instruction: instruction,
                    currentText: originalText,
                    selectedText: selection.text,
                    surroundingContext: context,
                    annotationContext: annotationContext,
                    sources: chunks,
                    configuration: config
                )
                guard !Task.isCancelled, self.generationID == generationID else { return }
                let outsideEdits = application.edits.filter {
                    !Self.contains(selection.range, range: $0.range)
                }
                let reasons = outsideEdits.compactMap(\.reason)
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if selectedDocument?.relativePath == document.relativePath,
                   editProposal == nil,
                   editorText == originalText {
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
            } catch is CancellationError {
                return
            } catch {
                guard self.generationID == generationID else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    func saveNow(ignoringExternalConflict: Bool = false) -> Bool {
        guard let document = selectedDocument,
              editorText != documentSession.loadedText else { return true }
        if !ignoringExternalConflict,
           externalConflict?.document.id == document.id {
            saveState = .failed("等待处理外部修改")
            return false
        }
        do {
            let refreshed = try documentSession.writeSynchronously(
                editorText,
                to: document,
                using: knowledgeBase
            )
            documentSession.loadedText = editorText
            persistAnnotations(for: document)
            saveState = .saved(.now)
            updateDocumentMetadata(refreshed)
            return true
        } catch {
            saveState = .failed(error.localizedDescription)
            errorMessage = "保存失败：\(error.localizedDescription)"
            return false
        }
    }

    func prepareForTermination() -> Bool {
        guard editProposal == nil else {
            errorMessage = "请先接受或取消当前修改，再退出知境。"
            return false
        }
        guard saveNow() else { return false }
        do {
            try chatPersistence.saveSynchronously(chats)
            try annotationPersistence.saveSynchronously(
                annotations,
                libraryRoot: libraryURL,
                externalDocuments: externalDocuments
            )
            return true
        } catch {
            errorMessage = "保存对话或批注失败：\(error.localizedDescription)"
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
                from: document,
                to: destination,
                newRelativePath: newRelativePath,
                updateSelection: wasSelected
            )
            do {
                try knowledgeBase.migrateRevisions(
                    from: document,
                    to: destination
                )
            } catch {
                errorMessage = "文稿已重命名，但历史版本迁移失败：\(error.localizedDescription)"
            }
            if wasSelected {
                clearDocumentSelection()
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
                from: document,
                to: destination,
                newRelativePath: newRelativePath,
                updateSelection: wasSelected
            )
            do {
                try knowledgeBase.migrateRevisions(
                    from: document,
                    to: destination
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
            var failedRevisionMigrations = 0
            for document in affectedDocuments {
                let suffix = String(document.relativePath.dropFirst(folder.count))
                let newPath = newFolder + suffix
                let newURL = root.appending(path: newPath)
                let isSelected = document.relativePath == selectedPath
                migrateDocumentState(
                    from: document,
                    to: newURL,
                    newRelativePath: newPath,
                    updateSelection: isSelected
                )
                do {
                    try knowledgeBase.migrateRevisions(
                        from: document,
                        to: newURL
                    )
                } catch {
                    failedRevisionMigrations += 1
                }
                if isSelected {
                    migratedSelection = newPath
                }
            }
            if selectedIsAffected {
                clearDocumentSelection()
            }
            if failedRevisionMigrations > 0 {
                errorMessage = "文件夹已重命名，但有 \(failedRevisionMigrations) 篇文稿的历史版本迁移失败。"
            }
            Task { await refreshLibrary(selecting: migratedSelection) }
        } catch {
            errorMessage = "重命名文件夹失败：\(error.localizedDescription)"
        }
    }

    func deleteFolder(_ folder: String) {
        guard let root = libraryURL, !folder.isEmpty else { return }
        let affectedDocuments = documents.filter {
            $0.folder == folder || $0.folder.hasPrefix(folder + "/")
        }
        let affectedPaths = affectedDocuments.map(\.relativePath)
        let affectedKeys = Set(affectedDocuments.map(\.persistenceKey))
        let selectedIsAffected = selectedDocument.map {
            affectedPaths.contains($0.relativePath)
        } ?? false

        do {
            if selectedIsAffected, !flushSave() { return }
            try knowledgeBase.trashFolder(root: root, relativePath: folder)
            favorites.subtract(affectedKeys)
            defaults.set(Array(favorites), forKey: Keys.favorites)
            for key in affectedKeys {
                chats[key] = nil
                annotations[key] = nil
            }
            openDocumentPaths.removeAll { affectedPaths.contains($0) }
            persistOpenDocuments()
            if let comparisonDocumentPath,
               affectedPaths.contains(comparisonDocumentPath) {
                setComparisonDocument(nil)
            }
            persistChats()
            persistAnnotations()
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
            let wasSelected = selectedDocument == document
            if wasSelected, !flushSave() { return }
            try knowledgeBase.trash(document)
            removeOpenDocument(document)
            favorites.remove(document.persistenceKey)
            defaults.set(Array(favorites), forKey: Keys.favorites)
            if comparisonDocumentPath == document.relativePath {
                setComparisonDocument(nil)
            }
            chats[document.persistenceKey] = nil
            annotations[document.persistenceKey] = nil
            persistChats()
            persistAnnotations()
            if wasSelected {
                documentSession.cancelAutosave()
                clearDocumentSelection()
            }
            Task { await refreshLibrary() }
        } catch {
            errorMessage = "移到废纸篓失败：\(error.localizedDescription)"
        }
    }

    func toggleFavorite(_ document: NoteDocument) {
        let key = document.persistenceKey
        if favorites.contains(key) {
            favorites.remove(key)
        } else {
            favorites.insert(key)
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
        let config: AIConfiguration
        do {
            config = try resolvedConfiguration()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard let generationID = beginGeneration() else { return }
        let key = document.persistenceKey
        let history = chats[key] ?? []
        let userMessage = ChatMessage(role: .user, text: question)
        chats[key, default: []].append(userMessage)
        persistChats()
        retrievalStatus = "正在搜索知识库…"

        let currentText = editorText
        let currentSelection = validEditorSelection()
        let currentAnnotations = currentAnnotations
        let scope = retrievalScope
        let allDocuments = documents
        let service = knowledgeBase
        let assistantMessageID = UUID()

        generationTask = Task {
            defer { finishGeneration(generationID) }
            let chunks = await Task.detached {
                service.retrieve(
                    query: question,
                    documents: allDocuments,
                    currentDocument: document,
                    scope: scope
                )
            }.value
            guard !Task.isCancelled, self.generationID == generationID else { return }
            retrievalStatus = "搜索了 \(Set(chunks.map(\.filePath)).count) 篇笔记，引用了 \(chunks.count) 个片段"
            let currentContext = Self.answerContext(
                question: question,
                document: document,
                text: currentText,
                selection: currentSelection,
                annotations: currentAnnotations
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
                            if selectedDocument?.id == document.id,
                               editProposal == nil,
                               editorText == currentText {
                                editProposal = EditProposal(
                                    documentPath: document.relativePath,
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
                if didCreateAssistantMessage {
                    updateAssistantMessage(
                        id: assistantMessageID,
                        documentPath: key,
                        text: streamedText.isEmpty ? "已停止生成。" : streamedText
                    )
                    persistChats()
                }
            } catch {
                guard self.generationID == generationID else { return }
                chats[key, default: []].append(ChatMessage(
                    role: .assistant,
                    text: "回答失败：\(error.localizedDescription)"
                ))
                persistChats()
            }
        }
    }

    func cancelGeneration() {
        generationID = nil
        let task = generationTask
        generationTask = nil
        task?.cancel()
        isGenerating = false
        retrievalStatus = "已停止生成"
    }

    func clearCurrentChat() {
        guard let key = selectedDocument?.persistenceKey else { return }
        chats[key] = []
        persistChats()
    }

    func proposeEdit(instruction: String) {
        guard let documentPath = selectedDocument?.relativePath,
              !editorText.isEmpty,
              editProposal == nil else { return }
        let config: AIConfiguration
        do {
            config = try resolvedConfiguration()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let originalText = editorText
        let annotationContext = Self.annotationContext(
            annotations: currentAnnotations,
            in: originalText
        )
        guard let generationID = beginGeneration() else { return }
        generationTask = Task {
            defer { finishGeneration(generationID) }
            do {
                let replacement = try await ai.proposeEdit(
                    instruction: instruction,
                    currentText: originalText,
                    annotationContext: annotationContext,
                    configuration: config
                )
                if !Task.isCancelled,
                   self.generationID == generationID,
                   selectedDocument?.relativePath == documentPath,
                   editProposal == nil,
                   editorText == originalText {
                    editProposal = EditProposal(
                        documentPath: documentPath,
                        original: originalText,
                        replacement: replacement,
                        instruction: instruction
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.generationID == generationID else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func resolveProposalHunk(
        hunkID: LineDiffHunk.ID,
        accepted: Bool,
        viewportFraction: Double
    ) {
        guard let proposal = editProposal,
              let document = selectedDocument else { return }
        guard proposal.canApply(
            to: document.relativePath,
            currentText: editorText
        ) else {
            errorMessage = "文稿已在审阅期间发生变化，无法安全处理这处修改。"
            return
        }
        guard validateExternalProposal(proposal, document: document) else {
            return
        }

        let diff = LineDiff(
            original: proposal.original,
            replacement: proposal.replacement
        )
        guard let resolution = diff.resolving(
            hunkID: hunkID,
            accepted: accepted
        ) else { return }

        do {
            if !snapshottedProposalIDs.contains(proposal.id) {
                _ = try knowledgeBase.createSnapshot(
                    text: proposal.original,
                    document: document,
                    name: proposal.source == .externalFile
                        ? "应用外部修改前"
                        : nil
                )
                if proposal.source == .externalFile {
                    _ = try knowledgeBase.createSnapshot(
                        text: proposal.replacement,
                        document: document,
                        name: "外部修改完整版本"
                    )
                }
                snapshottedProposalIDs.insert(proposal.id)
            }

            documentSession.cancelAutosave()
            let refreshed = try documentSession.writeSynchronously(
                resolution.settledText,
                to: document,
                using: knowledgeBase
            )
            replaceEditorText(resolution.settledText)
            documentSession.loadedText = resolution.settledText
            updateDocumentMetadata(refreshed)
            saveState = .saved(.now)

            if let remainingReplacement = resolution.remainingReplacement {
                editProposal = EditProposal(
                    id: proposal.id,
                    documentPath: proposal.documentPath,
                    original: resolution.settledText,
                    replacement: remainingReplacement,
                    instruction: proposal.instruction,
                    selectionLineRange: proposal.selectionLineRange,
                    selectionRange: proposal.selectionRange,
                    outsideSelectionReason: proposal.outsideSelectionReason,
                    source: proposal.source,
                    expectedDiskText: proposal.source == .externalFile
                        ? resolution.settledText
                        : nil
                )
                if proposal.source == .externalFile {
                    saveState = .reviewingExternalChange
                }
            } else {
                editProposal = nil
                snapshottedProposalIDs.remove(proposal.id)
                editorNavigationRequest = EditorNavigationRequest(
                    documentID: document.id,
                    line: resolution.settledLine,
                    verticalFraction: viewportFraction
                )
            }
            revisions = knowledgeBase.revisions(for: document)
        } catch {
            errorMessage = "处理这处修改失败：\(error.localizedDescription)"
        }
    }

    private func validateExternalProposal(
        _ proposal: EditProposal,
        document: NoteDocument
    ) -> Bool {
        guard proposal.source == .externalFile else { return true }
        do {
            let latestDiskText = try knowledgeBase.read(document)
            let expectedDiskText = proposal.expectedDiskText
                ?? proposal.replacement
            guard latestDiskText != expectedDiskText else { return true }
            snapshottedProposalIDs.remove(proposal.id)
            editProposal = EditProposal(
                documentPath: document.relativePath,
                original: editorText,
                replacement: latestDiskText,
                instruction: "外部文件在审阅期间又被改写，已更新为最新版本",
                source: .externalFile
            )
            saveState = .reviewingExternalChange
            errorMessage = "外部文件又有新修改，Diff 已更新，请重新确认。"
            return false
        } catch {
            errorMessage = "无法确认外部文件的最新内容：\(error.localizedDescription)"
            return false
        }
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

        let closingIndex = openDocuments.firstIndex(where: { $0.id == document.id }) ?? 0
        removeOpenDocument(document)

        if isLibraryDocument(document), comparisonDocumentPath == document.relativePath {
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

    func toggleAnnotationRail() {
        setAnnotationRailVisible(!isAnnotationRailVisible)
    }

    private func setAnnotationRailVisible(_ isVisible: Bool) {
        isAnnotationRailVisible = isVisible
        defaults.set(isVisible, forKey: Keys.annotationRailVisible)
        if !isVisible {
            annotationComposerRequest = nil
        }
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

    private static func answerContext(
        question: String,
        document: NoteDocument,
        text: String,
        selection: EditorTextSelection?,
        annotations: [TextAnnotation]
    ) -> String {
        let limit = 12_000
        let annotationText = annotationContext(
            annotations: annotations,
            in: text
        )
        guard text.utf16.count > limit else {
            return annotationText.isEmpty
                ? text
                : "\(text)\n\n---\n\n\(annotationText)"
        }

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

        if !annotationText.isEmpty {
            sections.append(annotationText)
        }

        return sections.joined(separator: "\n\n---\n\n")
    }

    private static func annotationContext(
        annotations: [TextAnnotation],
        in text: String
    ) -> String {
        guard !annotations.isEmpty else { return "" }
        let items = annotations.prefix(30).enumerated().map { index, annotation in
            let resolved = TextAnnotationAnchorResolver.resolve(annotation, in: text)
            let status = resolved == nil ? "（原文已修改或删除，位置待确认）" : ""
            return """
            [用户批注\(index + 1)]
            对应原文\(status)：\(annotation.anchor.selectedText)
            批注：\(annotation.text)
            """
        }.joined(separator: "\n\n")
        return """
        [用户批注]
        以下内容是用户附在原文上的持久批注，代表用户的判断、问题或修改意图，不是文稿中的事实或引用来源。

        \(items)
        """
    }

    private static func rangesOverlap(_ lhs: Range<Int>, _ rhs: Range<Int>) -> Bool {
        lhs.lowerBound < rhs.upperBound && rhs.lowerBound < lhs.upperBound
    }

    private func resolvedConfiguration() throws -> AIConfiguration {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKey.isEmpty {
            // AIService returns a local retrieval response before it reads the endpoint.
            return AIConfiguration(
                apiKey: apiKey,
                endpoint: URL(fileURLWithPath: "/"),
                model: model,
                provider: provider
            )
        }
        guard let endpoint = AIEndpointResolver.chatCompletionsURL(from: endpoint) else {
            throw NSError(
                domain: "AIConfiguration",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "基础地址无效。请输入包含 http:// 或 https:// 的完整接口地址。"
                ]
            )
        }
        return AIConfiguration(
            apiKey: apiKey,
            endpoint: endpoint,
            model: model,
            provider: provider
        )
    }

    private func configurationMatchesCurrent(_ configuration: AIConfiguration) -> Bool {
        guard let current = try? resolvedConfiguration() else { return false }
        return current.apiKey == configuration.apiKey &&
            current.endpoint == configuration.endpoint &&
            current.model == configuration.model &&
            current.provider == configuration.provider
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
            let refreshed = try documentSession.writeSynchronously(
                editorText,
                to: conflict.document,
                using: knowledgeBase
            )
            documentSession.loadedText = editorText
            updateDocumentMetadata(refreshed)
            externalConflict = nil
            saveState = .saved(.now)
            revisions = knowledgeBase.revisions(for: conflict.document)
            refreshAfterExternalResolution(conflict.document)
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
            documentSession.loadedText = diskText
            editProposal = nil
            externalConflict = nil
            saveState = .saved(.now)
            revisions = knowledgeBase.revisions(for: conflict.document)
            refreshAfterExternalResolution(conflict.document)
        } catch {
            errorMessage = "载入外部版本失败：\(error.localizedDescription)"
        }
    }

    func discardLocalVersionAfterExternalRemoval() {
        guard let conflict = externalConflict, conflict.fileWasRemoved else { return }
        externalConflict = nil
        if isLibraryDocument(conflict.document) {
            clearDocumentSelection()
            Task { await refreshLibrary() }
        } else {
            let closingIndex = openDocuments.firstIndex(where: {
                $0.id == conflict.document.id
            }) ?? 0
            removeOpenDocument(conflict.document)
            clearDocumentSelection()
            let remaining = openDocuments
            if !remaining.isEmpty {
                select(remaining[min(closingIndex, remaining.count - 1)])
            }
        }
    }

    @discardableResult
    private func flushSave() -> Bool {
        guard editProposal == nil else {
            errorMessage = "请先接受或取消当前修改。"
            return false
        }
        documentSession.cancelAutosave()
        return saveNow()
    }

    private func refreshDerivedLibraryState() {
        documentByPath = Dictionary(
            uniqueKeysWithValues: documents.map { ($0.relativePath, $0) }
        )
        migrateLegacyDocumentStateIfNeeded()
        recentDocuments = Array(
            documents.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(8)
        )
        favoriteDocuments = documents.filter {
            favorites.contains($0.persistenceKey)
        }

        libraryTree = LibraryTreeBuilder.build(
            folders: folders,
            documents: documents
        )
    }

    private func isLibraryDocument(_ document: NoteDocument) -> Bool {
        documentByPath[document.relativePath]?.id == document.id
    }

    private func reconcileMovedAnnotationDocuments(in root: URL) {
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath + "/"
        let staleEntries = annotations.filter { key, items in
            key.hasPrefix(prefix) &&
                !items.isEmpty &&
                !FileManager.default.fileExists(atPath: key)
        }
        guard !staleEntries.isEmpty else { return }

        var availableDocuments = documents.filter {
            annotations[$0.persistenceKey]?.isEmpty != false
        }
        var migrated = false
        for (oldKey, items) in staleEntries {
            let distinctiveEnough = items.count > 1 ||
                items.contains { $0.anchor.selectedText.count >= 12 }
            guard distinctiveEnough else { continue }

            let matches = availableDocuments.filter { document in
                guard let text = try? knowledgeBase.read(document) else { return false }
                return items.allSatisfy {
                    TextAnnotationAnchorResolver.resolve($0, in: text) != nil
                }
            }
            guard matches.count == 1, let destination = matches.first else { continue }
            annotations[oldKey] = nil
            annotations[destination.persistenceKey] = items
            availableDocuments.removeAll { $0.id == destination.id }
            migrated = true
        }
        if migrated {
            persistAnnotations()
        }
    }

    private static func makeExternalDocument(at url: URL) -> NoteDocument? {
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

    private func updateDocumentMetadata(_ refreshed: NoteDocument) {
        if let index = documents.firstIndex(where: { $0.id == refreshed.id }) {
            documents[index] = refreshed
            documentByPath[refreshed.relativePath] = refreshed
            recentDocuments.removeAll { $0.id == refreshed.id }
            recentDocuments.insert(refreshed, at: 0)
            recentDocuments = Array(
                recentDocuments.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(8)
            )
            if let favoriteIndex = favoriteDocuments.firstIndex(where: {
                $0.id == refreshed.id
            }) {
                favoriteDocuments[favoriteIndex] = refreshed
            }
        } else if let index = externalDocuments.firstIndex(where: {
            $0.id == refreshed.id
        }) {
            externalDocuments[index] = refreshed
            persistExternalDocuments()
        }
        if selectedDocument?.id == refreshed.id {
            selectedDocument = refreshed
        }
    }

    private func migrateExternalDocumentsIntoLibrary() {
        var migratedIDs: Set<String> = []
        for external in externalDocuments {
            guard let libraryDocument = documents.first(where: {
                $0.id == external.id
            }) else { continue }
            if !openDocumentPaths.contains(libraryDocument.relativePath) {
                openDocumentPaths.append(libraryDocument.relativePath)
            }
            if selectedDocument?.id == external.id {
                selectedDocument = libraryDocument
            }
            migratedIDs.insert(external.id)
        }
        guard !migratedIDs.isEmpty else { return }
        externalDocuments.removeAll { migratedIDs.contains($0.id) }
        persistOpenDocuments()
        persistExternalDocuments()
    }

    private func refreshAfterExternalResolution(_ document: NoteDocument) {
        if isLibraryDocument(document) {
            Task { await refreshLibrary(selecting: document.relativePath) }
        } else {
            if let refreshed = Self.makeExternalDocument(at: document.url),
               let index = externalDocuments.firstIndex(where: {
                   $0.id == document.id
               }) {
                externalDocuments[index] = refreshed
                selectedDocument = refreshed
                persistExternalDocuments()
            }
            startWatchingLibrary()
        }
    }

    private func clearDocumentSelection() {
        if isGenerating {
            cancelGeneration()
        }
        selectedDocument = nil
        editorSelection = nil
        annotationComposerRequest = nil
        hideDocumentFind()
        wordCountTask?.cancel()
        documentWordCount = 0
        replaceEditorText("", reanchoringAnnotations: false)
        documentSession.reset()
        revisions = []
        editProposal = nil
        externalConflict = nil
    }

    private func scheduleAutosave() {
        saveState = .saving
        guard let document = selectedDocument else { return }
        let text = editorText
        documentSession.scheduleAutosave(delay: .milliseconds(650)) { [weak self] in
            await self?.autosave(text: text, document: document)
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
            let refreshed = try await documentSession.write(
                text,
                to: document,
                using: knowledgeBase
            )
            guard selectedDocument?.id == document.id, editorText == text else { return }
            documentSession.loadedText = text
            persistAnnotations(for: document)
            saveState = .saved(.now)
            updateDocumentMetadata(refreshed)
        } catch {
            guard selectedDocument?.id == document.id, editorText == text else { return }
            saveState = .failed(error.localizedDescription)
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
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
            additionalFiles: externalDocuments.map(\.url),
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
                loadedText: documentSession.loadedText,
                editorText: editorText,
                diskText: diskText,
                knownLocalWriteSignatures: documentSession.localWriteSignatures(
                    for: document
                )
            ) {
            case .unchanged:
                break
            case .localChangesOnly:
                scheduleAutosave()
            case .synchronized(let text):
                documentSession.loadedText = text
                saveState = .saved(.now)
            case .localWriteObserved(let text):
                documentSession.loadedText = text
                scheduleAutosave()
            case .reloadFromDisk(let text):
                if let proposal = editProposal,
                   proposal.source == .assistant {
                    externalConflict = ExternalFileConflict(
                        document: document,
                        localText: editorText,
                        diskText: text,
                        detectedAt: .now
                    )
                    saveState = .failed("检测到外部修改")
                } else if editProposal?.replacement != text {
                    editProposal = EditProposal(
                        documentPath: document.relativePath,
                        original: editorText,
                        replacement: text,
                        instruction: "外部工具已完成文件修改，请确认差异",
                        source: .externalFile
                    )
                    hideDocumentFind()
                    saveState = .reviewingExternalChange
                }
            case .conflict(let text):
                externalConflict = ExternalFileConflict(
                    document: document,
                    localText: editorText,
                    diskText: text,
                    detectedAt: .now
                )
                saveState = .failed("检测到外部修改")
            case .removedCleanly:
                if !isLibraryDocument(document) {
                    let closingIndex = openDocuments.firstIndex(where: {
                        $0.id == document.id
                    }) ?? 0
                    removeOpenDocument(document)
                    clearDocumentSelection()
                    let remaining = openDocuments
                    if !remaining.isEmpty {
                        select(remaining[min(closingIndex, remaining.count - 1)])
                    }
                    errorMessage = "当前外部文稿已被移动或删除。"
                }
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

        if isLibraryDocument(document) {
            await refreshLibrary(selecting: document.relativePath)
        } else if let refreshed = Self.makeExternalDocument(at: document.url),
                  let index = externalDocuments.firstIndex(where: {
                      $0.id == document.id
                  }) {
            externalDocuments[index] = refreshed
            if selectedDocument?.id == document.id {
                selectedDocument = refreshed
            }
            persistExternalDocuments()
        }
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

    private func replaceEditorText(
        _ text: String,
        reanchoringAnnotations: Bool = true
    ) {
        if reanchoringAnnotations {
            _ = reanchorCurrentAnnotations(
                from: editorText,
                to: text,
                mutation: nil
            )
        }
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

    private func relativePath(for url: URL) -> String {
        guard let root = libraryURL?.standardizedFileURL else {
            return url.lastPathComponent
        }
        let path = url.standardizedFileURL.path
        return String(path.dropFirst(min(path.count, root.path.count + 1)))
    }

    private func migrateDocumentState(
        from document: NoteDocument,
        to destination: URL,
        newRelativePath: String,
        updateSelection: Bool
    ) {
        let oldPath = document.relativePath
        let oldKey = document.persistenceKey
        let newKey = destination.standardizedFileURL.path
        if favorites.remove(oldKey) != nil {
            favorites.insert(newKey)
            defaults.set(Array(favorites), forKey: Keys.favorites)
        }
        if let messages = chats.removeValue(forKey: oldKey) {
            chats[newKey] = messages
            persistChats()
        }
        if let documentAnnotations = annotations.removeValue(forKey: oldKey) {
            annotations[newKey] = documentAnnotations
            persistAnnotations()
        }
        if let index = openDocumentPaths.firstIndex(of: oldPath) {
            openDocumentPaths[index] = newRelativePath
            persistOpenDocuments()
        }
        if comparisonDocumentPath == oldPath {
            comparisonDocumentPath = newRelativePath
            defaults.set(newRelativePath, forKey: Keys.comparisonDocumentPath)
        }
        if updateSelection {
            defaults.set(newRelativePath, forKey: Keys.selectedPath)
        }
    }

    private func migrateLegacyDocumentStateIfNeeded() {
        let migration = DocumentStateStore.migrateLegacyKeys(
            favorites: favorites,
            chats: chats,
            documents: documents
        )
        guard migration.didChange else { return }
        favorites = migration.favorites
        chats = migration.chats
        defaults.set(Array(favorites), forKey: Keys.favorites)
        persistChats()
    }

    private func addOpenDocument(_ document: NoteDocument) {
        if isLibraryDocument(document) {
            guard !openDocumentPaths.contains(document.relativePath) else { return }
            openDocumentPaths.append(document.relativePath)
            persistOpenDocuments()
        } else {
            guard !externalDocuments.contains(where: { $0.id == document.id }) else {
                return
            }
            externalDocuments.append(document)
            persistExternalDocuments()
            startWatchingLibrary()
        }
    }

    private func removeOpenDocument(_ document: NoteDocument) {
        if isLibraryDocument(document) {
            openDocumentPaths.removeAll { $0 == document.relativePath }
            persistOpenDocuments()
        } else {
            externalDocuments.removeAll { $0.id == document.id }
            persistExternalDocuments()
            startWatchingLibrary()
        }
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

    private func persistExternalDocuments() {
        defaults.set(
            externalDocuments.map { $0.url.standardizedFileURL.path },
            forKey: Keys.externalDocumentPaths
        )
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

    private func transitionToLibrary(_ url: URL) {
        libraryRefreshID = UUID()
        libraryWatcher.stop()
        externalRefreshTask?.cancel()
        externalRefreshTask = nil
        pendingLibraryChangeURLs.removeAll()
        searchTask?.cancel()
        searchTask = nil
        searchResults = []
        clearDocumentSelection()
        resetWorkspaceNavigation()
        documents = []
        folders = []
        documentByPath = [:]
        libraryTree = []
        recentDocuments = []
        favoriteDocuments = []
        isIndexing = false

        let standardizedURL = url.standardizedFileURL
        loadedAnnotationRootPath = nil
        libraryURL = standardizedURL
        defaults.set(standardizedURL.path, forKey: Keys.libraryPath)
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
        chatPersistence.save(chats)
        defaults.removeObject(forKey: Keys.chats)
    }

    @discardableResult
    private func reanchorCurrentAnnotations(
        from oldText: String,
        to newText: String,
        mutation: EditorTextMutation?
    ) -> Bool {
        guard oldText != newText,
              let key = selectedDocument?.persistenceKey,
              let current = annotations[key],
              !current.isEmpty else { return false }
        let updated = current.map {
            TextAnnotationAnchorResolver.reanchor(
                $0,
                from: oldText,
                to: newText,
                mutation: mutation
            )
        }
        guard updated != current else { return false }
        annotations[key] = updated
        return true
    }

    private func loadPortableAnnotationsIfNeeded(at root: URL) {
        let rootPath = root.standardizedFileURL.path
        guard loadedAnnotationRootPath != rootPath else { return }
        let portableURL = root.appending(
            path: AnnotationPersistenceService.portableFilename
        )
        let hasPortableFile = FileManager.default.fileExists(atPath: portableURL.path)
        do {
            let portable = try annotationPersistence.loadLibrary(at: root)
            let prefix = rootPath + "/"
            if hasPortableFile {
                annotations = annotations.filter { !$0.key.hasPrefix(prefix) }
                annotations.merge(portable) { _, portableValue in portableValue }
            } else {
                let hasLegacyValues = annotations.contains {
                    $0.key.hasPrefix(prefix) && !$0.value.isEmpty
                }
                if hasLegacyValues {
                    annotationPersistence.saveLibrary(annotations, at: root)
                }
            }
            loadedAnnotationRootPath = rootPath
            annotationPersistenceBlockedRoots.remove(rootPath)
        } catch {
            annotationPersistenceBlockedRoots.insert(rootPath)
            errorMessage = "批注索引无法读取，已停止覆盖原文件：\(error.localizedDescription)"
        }
    }

    private func loadPortableAnnotations(for document: NoteDocument) {
        if isLibraryDocument(document) {
            if let libraryURL {
                loadPortableAnnotationsIfNeeded(at: libraryURL)
            }
            return
        }
        do {
            let items = try annotationPersistence.loadExternal(document: document)
            if !items.isEmpty {
                annotations[document.persistenceKey] = items
            }
        } catch {
            errorMessage = "外部文稿的批注文件无法读取：\(error.localizedDescription)"
        }
    }

    private func persistAnnotations(for document: NoteDocument? = nil) {
        annotationPersistence.save(annotations)
        if let root = libraryURL {
            let rootPath = root.standardizedFileURL.path
            if !annotationPersistenceBlockedRoots.contains(rootPath) {
                annotationPersistence.saveLibrary(annotations, at: root)
            }
        }
        if let document, !isLibraryDocument(document) {
            annotationPersistence.saveExternal(
                annotations[document.persistenceKey] ?? [],
                document: document
            )
        }
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
        static let annotationRailVisible = "annotationRailVisible"
        static let colorScheme = "colorScheme"
        static let openDocumentPaths = "openDocumentPaths"
        static let externalDocumentPaths = "externalDocumentPaths"
        static let comparisonVisible = "comparisonVisible"
        static let comparisonDocumentPath = "comparisonDocumentPath"
    }
}
