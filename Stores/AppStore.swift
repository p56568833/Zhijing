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
    var libraryURL: URL? {
        get { workspaceCatalog.libraryURL }
        set { workspaceCatalog.libraryURL = newValue }
    }
    var documents: [NoteDocument] {
        get { workspaceCatalog.documents }
        set { workspaceCatalog.documents = newValue }
    }
    var folders: [String] {
        get { workspaceCatalog.folders }
        set { workspaceCatalog.folders = newValue }
    }
    var libraryTree: [LibraryTreeItem] { workspaceCatalog.libraryTree }
    var recentDocuments: [NoteDocument] { workspaceCatalog.recentDocuments }
    var favoriteDocuments: [NoteDocument] { workspaceCatalog.favoriteDocuments }
    var selectedDocument: NoteDocument? {
        get { editorState.selectedDocument }
        set { editorState.selectedDocument = newValue }
    }
    private(set) var editorText: String {
        get { editorState.text }
        set { editorState.acceptUserText(newValue) }
    }
    var editorContentRevision: Int { editorState.contentRevision }
    var editorNavigationRequest: EditorNavigationRequest? {
        editorState.navigationRequest
    }
    private(set) var editorSelection: EditorTextSelection? {
        get { editorState.selection }
        set { editorState.updateSelection(newValue) }
    }
    var documentWordCount: Int { editorState.wordCount }
    var isDocumentFindVisible: Bool {
        get { documentFindController.isVisible }
        set { documentFindController.isVisible = newValue }
    }
    var documentFindOptions: DocumentFindOptions {
        get { documentFindController.options }
        set { documentFindController.options = newValue }
    }
    var documentFindResult: DocumentFindResult {
        documentFindController.result
    }
    var documentFindNavigationRequest: DocumentFindNavigationRequest? {
        documentFindController.navigationRequest
    }
    var selectionEditRequest: SelectionEditRequest?
    private(set) var annotationComposerRequest: AnnotationComposerRequest?
    private(set) var annotations: [String: [TextAnnotation]] = [:]
    var searchQuery: String {
        get { librarySearchController.query }
        set { librarySearchController.query = newValue }
    }
    var searchResults: [SearchHit] {
        get { librarySearchController.results }
        set { librarySearchController.results = newValue }
    }
    var favorites: Set<String> = []
    var saveState: SaveState {
        get { editorState.saveState }
        set { editorState.saveState = newValue }
    }
    var isIndexing: Bool {
        get { workspaceCatalog.isIndexing }
        set { workspaceCatalog.isIndexing = newValue }
    }
    var isAssistantVisible = true
    var isSidebarVisible = true
    var isAnnotationRailVisible = true
    var colorScheme = AppColorScheme.system {
        didSet { defaults.set(colorScheme.rawValue, forKey: Keys.colorScheme) }
    }
    var isPreviewMode = false
    var retrievalScope: RetrievalScope = .library
    var chats: [String: [ChatMessage]] {
        get { aiGenerationController.chats }
        set { aiGenerationController.chats = newValue }
    }
    var isGenerating: Bool { aiGenerationController.isGenerating }
    var retrievalStatus: String { aiGenerationController.retrievalStatus }
    var errorMessage: String?
    var editProposal: EditProposal? {
        get { editProposalController.proposal }
        set { editProposalController.proposal = newValue }
    }
    var revisions: [Revision] {
        get { revisionController.revisions }
        set { revisionController.revisions = newValue }
    }
    var provider: AIProviderPreset {
        get { aiSettings.provider }
        set { aiSettings.provider = newValue }
    }
    var isTestingConnection: Bool { aiSettings.isTestingConnection }
    var connectionTestSucceeded: Bool { aiSettings.connectionTestSucceeded }
    var connectionTestError: String? {
        get { aiSettings.connectionTestError }
        set { aiSettings.connectionTestError = newValue }
    }
    var accountBalances: [AIAccountBalance] { aiSettings.accountBalances }
    var balanceError: String? { aiSettings.balanceError }
    var isRefreshingBalance: Bool { aiSettings.isRefreshingBalance }
    var externalConflict: ExternalFileConflict? {
        get { externalConflictController.conflict }
        set { externalConflictController.conflict = newValue }
    }
    private(set) var openDocumentPaths: [String] = []
    private(set) var externalDocuments: [NoteDocument] = []
    var isComparisonVisible = false
    private(set) var comparisonDocumentPath: String?
    private(set) var comparisonText = ""

    var model: String {
        get { aiSettings.model }
        set { aiSettings.model = newValue }
    }
    var endpoint: String {
        get { aiSettings.endpoint }
        set { aiSettings.endpoint = newValue }
    }
    var excludedFoldersText = ".git, node_modules" {
        didSet { defaults.set(excludedFoldersText, forKey: Keys.excludedFolders) }
    }
    var apiKey: String {
        get { aiSettings.apiKey }
        set {
            aiSettings.apiKey = newValue
            if let persistenceError = aiSettings.secretPersistenceError {
                errorMessage = persistenceError
            }
        }
    }

    private let defaults: UserDefaults
    private let aiSettings: AISettingsController
    private let knowledgeBase: KnowledgeBaseService
    private let librarySearchController: LibrarySearchController
    private let revisionController: RevisionController
    private let aiGenerationController: AIGenerationController
    private let editProposalController: EditProposalController
    private let workspaceCatalog: WorkspaceCatalogController
    private let externalChangeMonitor: ExternalChangeMonitor
    private let externalConflictController: ExternalConflictController
    private let documentExporter = DocumentExportService()
    private let documentSession: DocumentSessionController
    private let editorState: EditorSessionState
    private let documentFindController = DocumentFindController()
    private let annotationRepository = AnnotationRepository()
    var currentMessages: [ChatMessage] {
        aiGenerationController.messages(
            for: selectedDocument?.persistenceKey
        )
    }

    var currentAnnotations: [TextAnnotation] {
        guard let key = selectedDocument?.persistenceKey else { return [] }
        return annotations[key] ?? []
    }

    var currentResolvedAnnotations: [ResolvedTextAnnotation] {
        currentAnnotationResolution.resolved
    }

    var currentAnnotationDisplayItems: [TextAnnotationDisplayItem] {
        currentAnnotationResolution.displayItems
    }

    private var currentAnnotationResolution: AnnotationResolutionSnapshot {
        annotationRepository.resolution(
            documentKey: selectedDocument?.persistenceKey,
            annotations: currentAnnotations,
            text: editorText
        )
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
        aiGenerationController.canCancel
    }

    var openDocuments: [NoteDocument] {
        let libraryDocuments = openDocumentPaths.compactMap { path in
            workspaceCatalog.document(at: path)
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
        return workspaceCatalog.document(at: comparisonDocumentPath)
    }

    var comparisonCandidates: [NoteDocument] {
        documents.filter { $0.id != selectedDocument?.id }
    }

    init(
        defaults: UserDefaults = .standard,
        knowledgeBase: KnowledgeBaseService = .init(),
        aiService: AIService = .init(),
        chatPersistence: ChatPersistenceService = .init(),
        documentSession: DocumentSessionController = .init()
    ) {
        self.defaults = defaults
        self.knowledgeBase = knowledgeBase
        self.documentSession = documentSession
        editorState = EditorSessionState()
        workspaceCatalog = WorkspaceCatalogController(service: knowledgeBase)
        externalChangeMonitor = ExternalChangeMonitor()
        librarySearchController = LibrarySearchController(
            service: knowledgeBase
        )
        revisionController = RevisionController(service: knowledgeBase)
        externalConflictController = ExternalConflictController(
            knowledgeBase: knowledgeBase,
            documentSession: documentSession,
            revisions: revisionController
        )
        editProposalController = EditProposalController(
            knowledgeBase: knowledgeBase,
            documentSession: documentSession,
            revisions: revisionController
        )
        aiGenerationController = AIGenerationController(
            ai: aiService,
            knowledgeBase: knowledgeBase,
            persistence: chatPersistence
        )
        aiSettings = AISettingsController(defaults: defaults)
        excludedFoldersText = defaults.string(forKey: Keys.excludedFolders) ?? ".git, node_modules"
        favorites = Set(defaults.stringArray(forKey: Keys.favorites) ?? [])
        let legacyChats = defaults.data(forKey: Keys.chats)
        do {
            try aiGenerationController.loadChats(legacyData: legacyChats)
        } catch {
            chats = [:]
            errorMessage = "对话记录无法读取，已停止覆盖原文件：\(error.localizedDescription)"
        }
        do {
            annotations = try annotationRepository.loadCachedAnnotations()
        } catch {
            annotations = [:]
            if errorMessage == nil {
                errorMessage = "批注缓存无法读取，已停止覆盖原文件：\(error.localizedDescription)"
            }
        }
        if legacyChats != nil {
            do {
                try aiGenerationController.saveSynchronously()
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
        aiSettings.selectProvider(newProvider)
    }

    func selectModel(_ newModel: String) {
        aiSettings.selectModel(newModel)
    }

    func testAIConnection(apiKey: String) async {
        await aiSettings.testConnection(apiKey: apiKey)
        if let persistenceError = aiSettings.secretPersistenceError {
            errorMessage = persistenceError
        }
    }

    func resetConnectionTest() {
        aiSettings.resetConnectionTest()
    }

    func refreshAccountBalance(force: Bool = false) async {
        await aiSettings.refreshAccountBalance(force: force)
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
        do {
            guard let scanned = try await workspaceCatalog.refresh(
                excludedFolders: excludedFolders,
                favorites: favorites
            ) else { return }
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
            if let targetPath,
               let target = workspaceCatalog.document(at: targetPath) {
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
                if let document = workspaceCatalog.document(at: path) {
                    addOpenDocument(document)
                }
            }
        } catch {
            errorMessage = "无法读取知识库：\(error.localizedDescription)"
        }
    }

    func select(_ document: NoteDocument) {
        if selectedDocument?.id == document.id {
            selectedDocument = workspaceCatalog.document(at: document.relativePath)
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
            revisionController.load(for: document)
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
        editorState.acceptUserText(text)
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
        editorState.navigate(
            to: EditorNavigationRequest(
                documentID: document.id,
                selectionRange: range
            )
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
        let config: AIConfiguration
        do {
            config = try resolvedConfiguration()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        aiGenerationController.proposeSelectionEdit(
            AISelectionProposalRequest(
                instruction: instruction,
                document: document,
                originalText: originalText,
                selection: selection,
                annotations: currentAnnotations,
                documents: documents,
                configuration: config
            ),
            onProposal: { [weak self] proposal in
                guard let self,
                      selectedDocument?.relativePath == document.relativePath,
                      editProposal == nil,
                      editorText == originalText else { return }
                editProposal = proposal
            },
            onError: { [weak self] message in
                self?.errorMessage = message
            }
        )
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
            try aiGenerationController.saveSynchronously()
            try annotationRepository.saveSynchronously(
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
                annotations[key] = nil
            }
            aiGenerationController.removeChats(for: affectedKeys)
            defaults.removeObject(forKey: Keys.chats)
            openDocumentPaths.removeAll { affectedPaths.contains($0) }
            persistOpenDocuments()
            if let comparisonDocumentPath,
               affectedPaths.contains(comparisonDocumentPath) {
                setComparisonDocument(nil)
            }
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
            aiGenerationController.removeChats(
                for: CollectionOfOne(document.persistenceKey)
            )
            defaults.removeObject(forKey: Keys.chats)
            annotations[document.persistenceKey] = nil
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
        librarySearchController.perform(documents: documents)
    }

    func sendMessage(_ text: String) {
        guard let document = selectedDocument else { return }
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isGenerating else { return }
        let configuration: AIConfiguration
        do {
            configuration = try resolvedConfiguration()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let currentText = editorText
        aiGenerationController.sendMessage(
            AIChatGenerationRequest(
                question: question,
                document: document,
                currentText: currentText,
                selection: validEditorSelection(),
                annotations: currentAnnotations,
                scope: retrievalScope,
                documents: documents,
                configuration: configuration
            ),
            onProposal: { [weak self] proposal in
                guard let self,
                      selectedDocument?.id == document.id,
                      editProposal == nil,
                      editorText == currentText else { return }
                editProposal = proposal
            },
            onDeepSeekCompletion: { [weak self] in
                guard let self else { return }
                await refreshAccountBalance(force: true)
            }
        )
    }
    func cancelGeneration() {
        aiGenerationController.cancelGeneration()
    }

    func clearCurrentChat() {
        guard let key = selectedDocument?.persistenceKey else { return }
        aiGenerationController.clearChat(for: key)
        defaults.removeObject(forKey: Keys.chats)
    }

    func proposeEdit(instruction: String) {
        guard let documentPath = selectedDocument?.relativePath,
              !editorText.isEmpty,
              editProposal == nil else { return }
        let configuration: AIConfiguration
        do {
            configuration = try resolvedConfiguration()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let originalText = editorText
        aiGenerationController.proposeDocumentEdit(
            AIDocumentProposalRequest(
                instruction: instruction,
                documentPath: documentPath,
                originalText: originalText,
                annotations: currentAnnotations,
                configuration: configuration
            ),
            onProposal: { [weak self] proposal in
                guard let self,
                      selectedDocument?.relativePath == documentPath,
                      editProposal == nil,
                      editorText == originalText else { return }
                editProposal = proposal
            },
            onError: { [weak self] message in
                self?.errorMessage = message
            }
        )
    }
    func resolveProposalHunk(
        hunkID: LineDiffHunk.ID,
        accepted: Bool,
        viewportFraction: Double
    ) {
        guard let document = selectedDocument else { return }
        do {
            guard let outcome = try editProposalController.resolve(
                hunkID: hunkID,
                accepted: accepted,
                document: document,
                currentText: editorText
            ) else { return }
            switch outcome {
            case let .applied(
                text,
                refreshedDocument,
                settledLine,
                isComplete,
                isExternal
            ):
                replaceEditorText(text)
                updateDocumentMetadata(refreshedDocument)
                saveState = isExternal && !isComplete
                    ? .reviewingExternalChange
                    : .saved(.now)
                if isComplete {
                    editorState.navigate(
                        to: EditorNavigationRequest(
                            documentID: document.id,
                            line: settledLine,
                            verticalFraction: viewportFraction
                        )
                    )
                }
            case .externalFileChanged(let message):
                saveState = .reviewingExternalChange
                errorMessage = message
            }
        } catch let error as EditProposalControllerError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "处理这处修改失败：\(error.localizedDescription)"
        }
    }
    func createManualSnapshot(name: String? = nil) {
        guard let document = selectedDocument else { return }
        do {
            _ = try revisionController.createSnapshot(
                text: editorText,
                document: document,
                name: name
            )
        } catch {
            errorMessage = "创建版本失败：\(error.localizedDescription)"
        }
    }

    func revisionText(_ revision: Revision) -> String {
        (try? revisionController.revisionText(revision)) ?? ""
    }

    func restore(_ revision: Revision) {
        guard let document = selectedDocument else { return }
        do {
            let restoredText = try revisionController.prepareRestore(
                revision,
                currentText: editorText,
                document: document
            )
            replaceEditorText(restoredText)
            saveNow()
            revisionController.load(for: document)
        } catch {
            errorMessage = "恢复版本失败：\(error.localizedDescription)"
        }
    }

    func openSource(_ source: RetrievedChunk) {
        if let document = documents.first(where: { $0.relativePath == source.filePath }) {
            select(document)
            isPreviewMode = false
            editorState.navigate(
                to: EditorNavigationRequest(
                    documentID: document.id,
                    line: source.line
                )
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
        documentFindController.show()
    }

    func hideDocumentFind() {
        documentFindController.hide()
    }

    func findNext() {
        guard selectedDocument != nil else { return }
        isPreviewMode = false
        documentFindController.navigate(.next)
    }

    func findPrevious() {
        guard selectedDocument != nil else { return }
        isPreviewMode = false
        documentFindController.navigate(.previous)
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
        documentFindController.updateResult(result)
    }

    private func resolvedConfiguration() throws -> AIConfiguration {
        try aiSettings.configuration()
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
            guard let refreshed = try externalConflictController
                .keepLocalVersion(editorText: editorText) else { return }
            updateDocumentMetadata(refreshed)
            saveState = .saved(.now)
            refreshAfterExternalResolution(conflict.document)
        } catch {
            errorMessage = "保留本地版本失败：\(error.localizedDescription)"
        }
    }

    func loadExternalVersionAfterConflict() {
        guard let conflict = externalConflict,
              conflict.diskText != nil,
              selectedDocument?.id == conflict.document.id else { return }
        do {
            guard let resolution = try externalConflictController
                .loadExternalVersion(editorText: editorText) else { return }
            replaceEditorText(resolution.text)
            editProposalController.reset()
            saveState = .saved(.now)
            refreshAfterExternalResolution(resolution.document)
        } catch {
            errorMessage = "载入外部版本失败：\(error.localizedDescription)"
        }
    }

    func discardLocalVersionAfterExternalRemoval() {
        guard let conflict = externalConflict, conflict.fileWasRemoved else { return }
        externalConflictController.clear()
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
        migrateLegacyDocumentStateIfNeeded()
        workspaceCatalog.rebuildDerivedState(favorites: favorites)
    }

    private func isLibraryDocument(_ document: NoteDocument) -> Bool {
        workspaceCatalog.isLibraryDocument(document)
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
        if isLibraryDocument(refreshed) {
            workspaceCatalog.updateDocumentMetadata(
                refreshed,
                favorites: favorites
            )
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
        editorState.clearDocument()
        annotationComposerRequest = nil
        hideDocumentFind()
        documentSession.reset()
        revisionController.reset()
        editProposalController.reset()
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

    private func startWatchingLibrary() {
        externalChangeMonitor.start(
            libraryRoot: libraryURL,
            additionalFiles: externalDocuments.map(\.url),
            excludedFolders: excludedFolders
        ) { [weak self] changedURLs in
            await self?.reconcileExternalChanges(changedURLs: changedURLs)
        }
    }
    private func reconcileExternalChanges(changedURLs: Set<URL>) async {
        guard let document = selectedDocument else {
            await refreshLibrary()
            return
        }

        let externalChange: ExternalFileChange?
        do {
            externalChange = try externalConflictController.evaluateChange(
                for: document,
                editorText: editorText,
                changedURLs: changedURLs
            )
        } catch {
            errorMessage = "无法读取外部修改：\(error.localizedDescription)"
            return
        }

        if let externalChange {
            switch externalChange {
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
                    externalConflictController.recordConflict(
                        document: document,
                        localText: editorText,
                        diskText: text
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
                externalConflictController.recordConflict(
                    document: document,
                    localText: editorText,
                    diskText: text
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
                externalConflictController.recordConflict(
                    document: document,
                    localText: editorText,
                    diskText: nil
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
        editorState.replaceText(text)
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
        aiGenerationController.moveChat(from: oldKey, to: newKey)
        defaults.removeObject(forKey: Keys.chats)
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
        workspaceCatalog.cancelRefresh()
        externalChangeMonitor.stop()
        librarySearchController.reset()
        clearDocumentSelection()
        resetWorkspaceNavigation()
        let standardizedURL = url.standardizedFileURL
        annotationRepository.transitionToLibrary()
        workspaceCatalog.transition(to: standardizedURL)
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
        aiGenerationController.persistChats()
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
        let updated = annotationRepository.reanchor(
            current,
            from: oldText,
            to: newText,
            mutation: mutation
        )
        guard updated != current else { return false }
        annotations[key] = updated
        return true
    }

    private func loadPortableAnnotationsIfNeeded(at root: URL) {
        do {
            try annotationRepository.loadLibraryIfNeeded(
                at: root,
                into: &annotations
            )
        } catch {
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
            guard let items = try annotationRepository.loadExternalAnnotations(
                for: document
            ) else { return }
            if items.isEmpty {
                annotations[document.persistenceKey] = nil
            } else {
                annotations[document.persistenceKey] = items
            }
        } catch {
            errorMessage = "外部文稿的批注文件无法读取：\(error.localizedDescription)"
        }
    }

    private func persistAnnotations(for document: NoteDocument? = nil) {
        let externalDocument = document.flatMap {
            isLibraryDocument($0) ? nil : $0
        }
        annotationRepository.save(
            annotations,
            libraryRoot: libraryURL,
            externalDocument: externalDocument
        )
    }

    private enum Keys {
        static let libraryPath = "libraryPath"
        static let selectedPath = "selectedPath"
        static let favorites = "favorites"
        static let chats = "chats"
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
