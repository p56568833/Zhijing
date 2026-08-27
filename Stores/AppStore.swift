import AppKit
import Foundation
import Observation

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
    var documentSpeakingDurationLabel: String {
        editorState.speakingDurationLabel
    }
    var selectionMetrics: DocumentMetrics? { editorState.selectionMetrics }
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
    var annotationComposerRequest: AnnotationComposerRequest? {
        annotationController.composerRequest
    }
    private(set) var inlineAnnotationRequestID = 0
    private(set) var formatRequest: EditorFormatRequest?

    func applyInlineFormat(_ command: EditorFormatCommand) {
        guard !isPreviewMode,
              selectedDocument != nil,
              editProposal == nil else {
            NSSound.beep()
            return
        }
        formatRequest = EditorFormatRequest(id: UUID(), command: command)
    }
    var searchQuery: String {
        get { librarySearchController.query }
        set { librarySearchController.query = newValue }
    }
    var searchResults: [SearchHit] {
        get { librarySearchController.results }
        set { librarySearchController.results = newValue }
    }
    var favorites: Set<String> {
        get { preferences.favorites }
        set { preferences.favorites = newValue }
    }
    var saveState: SaveState {
        get { editorState.saveState }
        set { editorState.saveState = newValue }
    }
    var isIndexing: Bool {
        get { workspaceCatalog.isIndexing }
        set { workspaceCatalog.isIndexing = newValue }
    }
    var isSidebarVisible: Bool {
        get { preferences.isSidebarVisible }
        set { preferences.isSidebarVisible = newValue }
    }
    var isAnnotationRailVisible: Bool {
        get { preferences.isAnnotationRailVisible }
        set { preferences.isAnnotationRailVisible = newValue }
    }
    var colorScheme: AppColorScheme {
        get { preferences.colorScheme }
        set { preferences.colorScheme = newValue }
    }
    var documentSort: AppDocumentSort {
        get { preferences.documentSort }
        set { preferences.documentSort = newValue }
    }
    var manualDocumentOrder: [String] {
        get { preferences.manualDocumentOrder }
        set { preferences.manualDocumentOrder = newValue }
    }
    var isPreviewMode = false
    var errorMessage: String?
    var editProposal: EditProposal? {
        get { editProposalController.proposal }
        set { editProposalController.proposal = newValue }
    }
    var revisions: [Revision] {
        get { revisionController.revisions }
        set { revisionController.revisions = newValue }
    }
    var externalConflict: ExternalFileConflict? {
        get { externalConflictController.conflict }
        set { externalConflictController.conflict = newValue }
    }
    private(set) var openDocumentPaths: [String] {
        get { workspaceNavigation.openDocumentPaths }
        set { workspaceNavigation.openDocumentPaths = newValue }
    }
    private(set) var externalDocuments: [NoteDocument] {
        get { workspaceNavigation.externalDocuments }
        set { workspaceNavigation.externalDocuments = newValue }
    }
    var isComparisonVisible: Bool {
        get { workspaceNavigation.isComparisonVisible }
        set { workspaceNavigation.isComparisonVisible = newValue }
    }
    private(set) var comparisonDocumentPath: String? {
        get { workspaceNavigation.comparisonDocumentPath }
        set { workspaceNavigation.comparisonDocumentPath = newValue }
    }
    private(set) var comparisonText: String {
        get { workspaceNavigation.comparisonText }
        set { workspaceNavigation.comparisonText = newValue }
    }

    var excludedFoldersText: String {
        get { preferences.excludedFoldersText }
        set { preferences.excludedFoldersText = newValue }
    }
    private let defaults: UserDefaults
    private let preferences: AppPreferencesController
    private let knowledgeBase: KnowledgeBaseService
    private let librarySearchController: LibrarySearchController
    private let revisionController: RevisionController
    private let editProposalController: EditProposalController
    private let workspaceCatalog: WorkspaceCatalogController
    private let workspaceNavigation: WorkspaceNavigationController
    private let externalChangeMonitor: ExternalChangeMonitor
    private let externalConflictController: ExternalConflictController
    private let documentExporter = DocumentExportService()
    private let documentSession: DocumentSessionController
    private let editorState: EditorSessionState
    private let documentFindController = DocumentFindController()
    private let annotationController: AnnotationController
    private var documentSelectionRefreshTask: Task<Void, Never>?
    var currentAnnotations: [TextAnnotation] {
        annotationController.annotations(for: selectedDocument)
    }

    var currentResolvedAnnotations: [ResolvedTextAnnotation] {
        currentAnnotationResolution.resolved
    }

    var currentAnnotationDisplayItems: [TextAnnotationDisplayItem] {
        currentAnnotationResolution.displayItems
    }

    private var currentAnnotationResolution: AnnotationResolutionSnapshot {
        annotationController.resolution(
            for: selectedDocument,
            text: editorText
        )
    }

    var openDocuments: [NoteDocument] {
        workspaceNavigation.openDocuments(in: documents)
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
        documentSession: DocumentSessionController = .init()
    ) {
        self.defaults = defaults
        preferences = AppPreferencesController(defaults: defaults)
        self.knowledgeBase = knowledgeBase
        self.documentSession = documentSession
        editorState = EditorSessionState()
        workspaceNavigation = WorkspaceNavigationController(defaults: defaults)
        annotationController = AnnotationController(
            knowledgeBase: knowledgeBase
        )
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
        do {
            try annotationController.loadCachedAnnotations()
        } catch {
            annotationController.discardCachedAnnotations()
            if errorMessage == nil {
                errorMessage = "批注缓存无法读取，已停止覆盖原文件：\(error.localizedDescription)"
            }
        }
        if let path = defaults.string(forKey: Keys.libraryPath) {
            let url = URL(filePath: path, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: url.path) {
                libraryURL = url
                scheduleDocumentSelectionRefresh(
                    selecting: defaults.string(forKey: Keys.selectedPath)
                )
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
        documentSelectionRefreshTask?.cancel()
        if !isInCurrentLibrary {
            guard flushSave() else { return }
            transitionToLibrary(root)
        }

        let externalDocuments = request.externalURLs.compactMap {
            WorkspaceNavigationController.makeExternalDocument(at: $0)
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
        } else if let firstPath = request.relativePaths.first,
                  let first = workspaceCatalog.document(at: firstPath) {
            // When the library is already loaded, honor the Finder/open request
            // immediately instead of briefly showing the restored document.
            select(first)
        } else if !firstIsExternal,
                  !request.relativePaths.isEmpty,
                  selectedDocument != nil {
            guard flushSave() else { return }
            clearDocumentSelection()
        }

        if !request.relativePaths.isEmpty || !isInCurrentLibrary {
            scheduleDocumentSelectionRefresh(
                selecting: firstIsExternal ? nil : request.relativePaths.first,
                opening: request.relativePaths
            )
        }
    }

    func refreshLibrary(
        selecting relativePath: String? = nil,
        opening relativePaths: [String] = [],
        followMoves: Bool = true
    ) async {
        guard !Task.isCancelled else { return }
        guard let libraryURL else { return }
        loadPortableAnnotationsIfNeeded(at: libraryURL)
        let previousDocuments = workspaceCatalog.documents
        do {
            guard let scanned = try await workspaceCatalog.refresh(
                excludedFolders: excludedFolders,
                favorites: favorites
            ) else { return }
            guard !Task.isCancelled else { return }
            if followMoves {
                followExternallyMovedDocuments(previousDocuments: previousDocuments)
            }
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
                } else if externalConflict?.document.id == selectedDocument.id {
                    return
                } else {
                    let hadUnsavedChanges = editorText != documentSession.loadedText
                    documentSession.cancelAutosave()
                    clearDocumentSelection()
                    if hadUnsavedChanges {
                        errorMessage = "当前文稿已不在知识库中，可能被其他应用移动或删除。"
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

    /// 知识库重新扫描后，尝试为"路径消失"的已打开文稿找到新位置。
    /// 命中时沿用应用内移动的状态迁移（收藏、批注、标签页、历史版本），
    /// 未命中时保持原状，交由常规的外部冲突流程兜底。
    @discardableResult
    private func followExternallyMovedDocuments(previousDocuments: [NoteDocument]) -> Bool {
        let previousByPath = Dictionary(
            uniqueKeysWithValues: previousDocuments.map { ($0.relativePath, $0) }
        )
        var trackedPaths = openDocumentPaths
        if let selected = selectedDocument,
           isLibraryDocument(selected),
           externalConflict?.document.id != selected.id,
           !trackedPaths.contains(selected.relativePath) {
            trackedPaths.append(selected.relativePath)
        }
        let currentPaths = Set(documents.map(\.relativePath))
        let trackedDocuments: [NoteDocument] = trackedPaths.compactMap { previousByPath[$0] }
            .filter { !currentPaths.contains($0.relativePath) }
        guard !trackedDocuments.isEmpty else { return false }

        let previousPaths = Set(previousDocuments.map(\.relativePath))
        let appearedDocuments = documents.filter { !previousPaths.contains($0.relativePath) }
        guard !appearedDocuments.isEmpty else { return false }

        let matches = ExternalMoveMatcher.match(
            vanished: trackedDocuments,
            appeared: appearedDocuments
        )
        var followedSelection = false
        for match in matches {
            let isSelected = match.vanished.id == selectedDocument?.id
            let hasUnsavedChanges =
                isSelected && editorText != documentSession.loadedText
            if hasUnsavedChanges {
                guard let diskText = try? knowledgeBase.read(match.destination),
                      diskText == documentSession.loadedText else { continue }
            }
            migrateDocumentState(
                from: match.vanished,
                to: match.destination.url,
                newRelativePath: match.destination.relativePath,
                updateSelection: isSelected
            )
            try? knowledgeBase.migrateRevisions(
                from: match.vanished,
                to: match.destination.url
            )
            if isSelected {
                followedSelection = true
                if hasUnsavedChanges {
                    documentSession.cancelAutosave()
                    selectedDocument = match.destination
                    revisionController.load(for: match.destination)
                    scheduleAutosave()
                } else {
                    select(match.destination)
                }
            }
        }
        return followedSelection
    }

    func select(_ document: NoteDocument) {
        if selectedDocument?.id == document.id {
            selectedDocument = workspaceCatalog.document(at: document.relativePath)
                ?? externalDocuments.first(where: { $0.id == document.id })
                ?? document
            return
        }
        guard flushSave() else { return }
        annotationController.cancelComposing()
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

    func readingSelectionDidChange(_ text: String?) {
        editorState.updateMetricSelection(text)
    }

    func requestAnnotationComposer() {
        guard !isPreviewMode, let selection = validEditorSelection() else {
            NSSound.beep()
            return
        }
        editorSelection = selection
        inlineAnnotationRequestID &+= 1
    }

    func beginAnnotation(for selection: EditorTextSelection) {
        guard !isPreviewMode,
              validEditorSelection(selection) != nil else {
            NSSound.beep()
            return
        }
        annotationController.beginComposing(for: selection)
        setAnnotationRailVisible(true)
    }

    func cancelAnnotationComposer() {
        annotationController.cancelComposing()
    }

    func addAnnotation(
        text: String,
        selection: EditorTextSelection
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let document = selectedDocument,
              let validSelection = validEditorSelection(selection),
              annotationController.add(
                  text: value,
                  selection: validSelection,
                  document: document,
                  documentText: editorText
              ) else { return }
        persistAnnotations(for: document)
    }

    func updateAnnotation(id: UUID, text: String) {
        guard annotationController.update(
            id: id,
            text: text,
            document: selectedDocument
        ) else { return }
        persistAnnotations(for: selectedDocument)
    }

    func deleteAnnotation(id: UUID) {
        guard annotationController.delete(
            id: id,
            document: selectedDocument
        ) else { return }
        persistAnnotations(for: selectedDocument)
    }

    func toggleAnnotationResolution(id: UUID) {
        guard annotationController.toggleResolution(
            id: id,
            document: selectedDocument
        ) else { return }
        persistAnnotations(for: selectedDocument)
    }

    func relinkAnnotation(id: UUID) {
        guard let document = selectedDocument,
              let selection = validEditorSelection(),
              annotationController.relink(
                  id: id,
                  selection: selection,
                  document: document,
                  documentText: editorText
              ) else {
            NSSound.beep()
            return
        }
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
            try annotationController.saveSynchronously(
                libraryRoot: libraryURL,
                externalDocuments: externalDocuments
            )
            return true
        } catch {
            errorMessage = "保存批注失败：\(error.localizedDescription)"
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
            Task {
                await refreshLibrary(
                    selecting: wasSelected ? newRelativePath : nil,
                    followMoves: false
                )
            }
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
            Task {
                await refreshLibrary(
                    selecting: wasSelected ? newRelativePath : nil,
                    followMoves: false
                )
            }
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
            Task {
                await refreshLibrary(
                    selecting: migratedSelection,
                    followMoves: false
                )
            }
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
            annotationController.removeAnnotations(for: affectedKeys)
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
            Task {
                await refreshLibrary(followMoves: false)
            }
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
            if comparisonDocumentPath == document.relativePath {
                setComparisonDocument(nil)
            }
            annotationController.removeAnnotations(
                for: CollectionOfOne(document.persistenceKey)
            )
            persistAnnotations()
            if wasSelected {
                documentSession.cancelAutosave()
                clearDocumentSelection()
            }
            Task {
                await refreshLibrary(followMoves: false)
            }
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
        refreshDerivedLibraryState()
    }

    func performSearch() {
        librarySearchController.perform(documents: documents)
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

    func navigateToOutlineItem(_ item: DocumentOutlineItem) {
        guard let document = selectedDocument else { return }
        isPreviewMode = false
        editorState.navigate(
            to: EditorNavigationRequest(
                documentID: document.id,
                line: item.line
            )
        )
    }

    func select(_ document: NoteDocument, atLine line: Int) {
        select(document)
        isPreviewMode = false
        editorState.navigate(
            to: EditorNavigationRequest(
                documentID: document.id,
                line: line
            )
        )
    }

    /// 阅读模式下点击任务复选框：直接改写对应行的 [ ] / [x] 标记，
    /// 走常规编辑管线以获得自动保存与撤销支持。
    func toggleTaskCheckbox(atLine line: Int) {
        guard selectedDocument != nil else { return }
        let nsText = editorText as NSString
        guard line >= 1 else { return }
        var location = 0
        var currentLine = 1
        while currentLine < line, location < nsText.length {
            location = NSMaxRange(
                nsText.lineRange(for: NSRange(location: location, length: 0))
            )
            currentLine += 1
        }
        guard location <= nsText.length else { return }
        let lineRange = nsText.lineRange(
            for: NSRange(location: min(location, nsText.length), length: 0)
        )
        let lineText = nsText.substring(with: lineRange)
        guard let updated = DocumentTaskList.toggled(lineText) else { return }
        editorDidChange(nsText.replacingCharacters(in: lineRange, with: updated))
    }

    func revealInFinder(_ document: NoteDocument) {
        NSWorkspace.shared.activateFileViewerSelecting([document.url])
    }

    /// 拖拽标签页换位：按显示顺序重排打开列表并持久化。
    func moveDocumentTab(_ document: NoteDocument, toIndex targetIndex: Int) {
        let order = openDocuments
        guard let fromIndex = order.firstIndex(where: { $0.id == document.id })
        else { return }
        let newOrder = DocumentOrdering.moved(
            order,
            fromIndex: fromIndex,
            toIndex: targetIndex
        )
        guard newOrder != order else { return }
        let libraryPaths = newOrder
            .filter { isLibraryDocument($0) }
            .map(\.relativePath)
        let externals = newOrder.filter { !isLibraryDocument($0) }
        openDocumentPaths = libraryPaths
        externalDocuments = externals
        persistOpenDocuments()
        persistExternalDocuments()
    }

    /// 拖拽文库列表排序：把可见列表的新顺序合并进全局手动顺序并持久化。
    func setManualDocumentOrder(_ visibleOrder: [NoteDocument]) {
        manualDocumentOrder = DocumentOrdering.mergedManualOrder(
            visible: visibleOrder.map(\.relativePath),
            previous: manualDocumentOrder,
            universe: documents.map(\.relativePath)
        )
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
            workspaceNavigation.persistComparisonVisibility()
        }
    }

    func toggleComparison() {
        if isComparisonVisible {
            isComparisonVisible = false
            workspaceNavigation.persistComparisonVisibility()
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
        workspaceNavigation.persistComparisonVisibility()
    }

    func setComparisonDocument(_ relativePath: String?) {
        guard let relativePath,
              relativePath != selectedDocument?.relativePath,
              documents.contains(where: { $0.relativePath == relativePath }) else {
            comparisonDocumentPath = nil
            comparisonText = ""
            workspaceNavigation.persistComparisonDocument()
            return
        }
        comparisonDocumentPath = relativePath
        workspaceNavigation.persistComparisonDocument()
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

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    func toggleAnnotationRail() {
        setAnnotationRailVisible(!isAnnotationRailVisible)
    }

    private func setAnnotationRailVisible(_ isVisible: Bool) {
        isAnnotationRailVisible = isVisible
        if !isVisible {
            annotationController.cancelComposing()
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
        if annotationController.reconcileMovedDocuments(
            in: root,
            documents: documents
        ) {
            persistAnnotations()
        }
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
            if let refreshed = WorkspaceNavigationController.makeExternalDocument(
                at: document.url
            ),
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
        editorState.clearDocument()
        annotationController.cancelComposing()
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
                if editProposal?.replacement != text {
                    editProposal = EditProposal(
                        documentPath: document.relativePath,
                        original: editorText,
                        replacement: text
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
        } else if let refreshed = WorkspaceNavigationController.makeExternalDocument(
            at: document.url
        ),
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
        }
        if annotationController.moveAnnotations(from: oldKey, to: newKey) {
            persistAnnotations()
        }
        if let index = openDocumentPaths.firstIndex(of: oldPath) {
            openDocumentPaths[index] = newRelativePath
            persistOpenDocuments()
        }
        if comparisonDocumentPath == oldPath {
            comparisonDocumentPath = newRelativePath
            workspaceNavigation.persistComparisonDocument()
        }
        if updateSelection {
            defaults.set(newRelativePath, forKey: Keys.selectedPath)
        }
    }

    private func migrateLegacyDocumentStateIfNeeded() {
        let migration = DocumentStateStore.migrateLegacyKeys(
            favorites: favorites,
            documents: documents
        )
        guard migration.didChange else { return }
        favorites = migration.favorites
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
        workspaceNavigation.persistOpenDocuments()
    }

    private func persistExternalDocuments() {
        workspaceNavigation.persistExternalDocuments()
    }

    private func resetWorkspaceNavigation() {
        workspaceNavigation.resetForLibraryTransition()
    }

    private func transitionToLibrary(_ url: URL) {
        documentSelectionRefreshTask?.cancel()
        workspaceCatalog.cancelRefresh()
        externalChangeMonitor.stop()
        librarySearchController.reset()
        clearDocumentSelection()
        resetWorkspaceNavigation()
        let standardizedURL = url.standardizedFileURL
        annotationController.transitionToLibrary()
        workspaceCatalog.transition(to: standardizedURL)
        defaults.set(standardizedURL.path, forKey: Keys.libraryPath)
    }

    private func scheduleDocumentSelectionRefresh(
        selecting relativePath: String?,
        opening relativePaths: [String] = []
    ) {
        documentSelectionRefreshTask?.cancel()
        documentSelectionRefreshTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.refreshLibrary(
                selecting: relativePath,
                opening: relativePaths
            )
        }
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
            workspaceNavigation.persistComparisonVisibility()
        }
    }

    private func reloadComparisonDocument() {
        guard let document = comparisonDocument else {
            comparisonText = ""
            if comparisonDocumentPath != nil {
                comparisonDocumentPath = nil
                workspaceNavigation.persistComparisonDocument()
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

    @discardableResult
    private func reanchorCurrentAnnotations(
        from oldText: String,
        to newText: String,
        mutation: EditorTextMutation?
    ) -> Bool {
        annotationController.reanchor(
            document: selectedDocument,
            from: oldText,
            to: newText,
            mutation: mutation
        )
    }

    private func loadPortableAnnotationsIfNeeded(at root: URL) {
        do {
            try annotationController.loadLibraryIfNeeded(at: root)
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
            try annotationController.loadExternalAnnotations(for: document)
        } catch {
            errorMessage = "外部文稿的批注文件无法读取：\(error.localizedDescription)"
        }
    }

    private func persistAnnotations(for document: NoteDocument? = nil) {
        let externalDocument = document.flatMap {
            isLibraryDocument($0) ? nil : $0
        }
        annotationController.save(
            libraryRoot: libraryURL,
            externalDocument: externalDocument
        )
    }

    private enum Keys {
        static let libraryPath = "libraryPath"
        static let selectedPath = "selectedPath"
    }
}
