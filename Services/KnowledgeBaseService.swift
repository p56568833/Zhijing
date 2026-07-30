import Foundation

struct LibraryScanResult: Sendable {
    let documents: [NoteDocument]
    let folders: [String]
}

struct KnowledgeBaseService: Sendable {
    private var fileManager: FileManager { .default }
    private let allowedExtensions = NoteDocument.supportedFileExtensions
    private let contentCache = ContentCache()
    private let searchIndex = KnowledgeSearchIndex()
    private let supportDirectoryOverride: URL?

    init(supportDirectoryOverride: URL? = nil) {
        self.supportDirectoryOverride = supportDirectoryOverride
    }

    func scan(root: URL, excludedFolders: [String]) throws -> [NoteDocument] {
        try scanLibrary(root: root, excludedFolders: excludedFolders).documents
    }

    func scanFolders(root: URL, excludedFolders: [String]) throws -> [String] {
        try scanLibrary(root: root, excludedFolders: excludedFolders).folders
    }

    func scanLibrary(
        root: URL,
        excludedFolders: [String]
    ) throws -> LibraryScanResult {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .contentModificationDateKey,
            .fileSizeKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return LibraryScanResult(documents: [], folders: []) }

        let exclusions = Set(excludedFolders)
        var notes: [NoteDocument] = []
        var folders: [String] = []
        for case let url as URL in enumerator {
            let relative = relativePath(of: url, root: root)
            let components = relative.split(separator: "/").map(String.init)
            let values = try url.resourceValues(forKeys: Set(keys))
            if components.contains(where: exclusions.contains) {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            if values.isDirectory == true {
                folders.append(relative)
                continue
            }
            if AnnotationPersistenceService.isPersistenceFile(url) {
                continue
            }
            guard values.isRegularFile == true,
                  allowedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            notes.append(NoteDocument(
                url: url,
                relativePath: relative,
                modifiedAt: values.contentModificationDate ?? .distantPast,
                size: values.fileSize ?? 0
            ))
        }
        return LibraryScanResult(
            documents: notes.sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            },
            folders: folders.sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
        )
    }

    func read(_ document: NoteDocument) throws -> String {
        try String(contentsOf: document.url, encoding: .utf8)
    }

    @discardableResult
    func write(_ text: String, to document: NoteDocument) throws -> NoteDocument {
        try text.write(to: document.url, atomically: true, encoding: .utf8)
        var refreshedURL = document.url
        refreshedURL.removeAllCachedResourceValues()
        let values = try? refreshedURL.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey,
        ])
        let refreshed = NoteDocument(
            url: refreshedURL,
            relativePath: document.relativePath,
            modifiedAt: values?.contentModificationDate ?? .now,
            size: values?.fileSize ?? text.utf8.count
        )
        contentCache.set(refreshed, text)
        searchIndex.invalidate(document)
        return refreshed
    }

    func createNote(root: URL, folder: String? = nil) throws -> URL {
        let directory = folder.map { root.appending(path: $0, directoryHint: .isDirectory) } ?? root
        var candidate = directory.appending(path: "未命名文稿.md")
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "未命名文稿 \(index).md")
            index += 1
        }
        try "# 未命名文稿\n\n".write(to: candidate, atomically: true, encoding: .utf8)
        return candidate
    }

    func createFolder(root: URL, parent: String? = nil) throws -> URL {
        let directory = parent.map { root.appending(path: $0, directoryHint: .isDirectory) } ?? root
        var candidate = directory.appending(path: "新建文件夹", directoryHint: .isDirectory)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "新建文件夹 \(index)", directoryHint: .isDirectory)
            index += 1
        }
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
        return candidate
    }

    func rename(_ document: NoteDocument, to rawName: String) throws -> URL {
        let cleaned = cleanedFilename(rawName)
        guard !cleaned.isEmpty else { return document.url }
        let ext = document.url.pathExtension
        let filename = cleaned.hasSuffix(".\(ext)") ? cleaned : "\(cleaned).\(ext)"
        let destination = document.url.deletingLastPathComponent().appending(path: filename)
        guard destination.standardizedFileURL != document.url.standardizedFileURL else {
            return document.url
        }
        try ensureDestinationIsAvailable(destination)
        try fileManager.moveItem(at: document.url, to: destination)
        contentCache.remove(document)
        searchIndex.invalidate(document)
        return destination
    }

    func move(
        _ document: NoteDocument,
        toFolder relativeFolder: String,
        root: URL
    ) throws -> URL {
        let directory = relativeFolder.isEmpty
            ? root
            : root.appending(path: relativeFolder, directoryHint: .isDirectory)
        try ensureContained(directory, in: root)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }
        let destination = directory.appending(path: document.url.lastPathComponent)
        guard destination.standardizedFileURL != document.url.standardizedFileURL else {
            return document.url
        }
        try ensureDestinationIsAvailable(destination)
        try fileManager.moveItem(at: document.url, to: destination)
        contentCache.remove(document)
        searchIndex.invalidate(document)
        return destination
    }

    func renameFolder(
        root: URL,
        relativePath: String,
        to rawName: String
    ) throws -> URL {
        let cleaned = cleanedFilename(rawName)
        guard !cleaned.isEmpty, !relativePath.isEmpty else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let source = root.appending(path: relativePath, directoryHint: .isDirectory)
        try ensureContained(source, in: root)
        let destination = source.deletingLastPathComponent()
            .appending(path: cleaned, directoryHint: .isDirectory)
        guard destination.standardizedFileURL != source.standardizedFileURL else {
            return source
        }
        try ensureDestinationIsAvailable(destination)
        try fileManager.moveItem(at: source, to: destination)
        return destination
    }

    func trashFolder(root: URL, relativePath: String) throws {
        guard !relativePath.isEmpty else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let folder = root.appending(path: relativePath, directoryHint: .isDirectory)
        try ensureContained(folder, in: root)
        try fileManager.trashItem(at: folder, resultingItemURL: nil)
    }

    func trash(_ document: NoteDocument) throws {
        try fileManager.trashItem(at: document.url, resultingItemURL: nil)
        contentCache.remove(document)
        searchIndex.invalidate(document)
    }

    func search(
        query: String,
        documents: [NoteDocument],
        currentFolder: String? = nil,
        limit: Int = 60
    ) -> [SearchHit] {
        let terms = SearchTokenization.tokenize(query)
        guard !terms.isEmpty else { return [] }
        contentCache.reconcile(documents)
        searchIndex.reconcile(documents: documents)
        let candidates = currentFolder.map { folder in
            documents.filter { $0.folder == folder || $0.folder.hasPrefix(folder + "/") }
        } ?? documents

        return searchIndex.search(
            query: query,
            documents: candidates,
            limit: limit
        ) { document in
            cachedOrRead(document)
        }
    }

    func prepareSearchIndex(documents: [NoteDocument]) {
        contentCache.reconcile(documents)
        searchIndex.prepare(documents: documents) { document in
            cachedOrRead(document)
        }
    }

    func retrieve(
        query: String,
        documents: [NoteDocument],
        currentDocument: NoteDocument?,
        scope: RetrievalScope,
        limit: Int = 6
    ) -> [RetrievedChunk] {
        let folder = scope == .currentFolder ? currentDocument?.folder : nil
        let hits = search(query: query, documents: documents, currentFolder: folder, limit: limit * 3)
        var acceptedLines: [String: [Int]] = [:]
        return hits.compactMap { hit in
            let nearbyLines = acceptedLines[hit.document.relativePath, default: []]
            guard !nearbyLines.contains(where: { abs($0 - hit.line) <= 2 }) else { return nil }
            acceptedLines[hit.document.relativePath, default: []].append(hit.line)
            return RetrievedChunk(
                filePath: hit.document.relativePath,
                fileName: hit.document.url.lastPathComponent,
                heading: nearestHeading(in: hit.document, before: hit.line),
                text: hit.excerpt,
                line: hit.line,
                score: hit.score
            )
        }.prefix(limit).map { $0 }
    }

    func createSnapshot(
        text: String,
        document: NoteDocument,
        name: String? = nil
    ) throws -> URL {
        let base = try revisionDirectory(for: document, migrateLegacy: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        let createdAt = Date.now
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: createdAt)
            .replacingOccurrences(of: ":", with: "-")
        let filename = "\(timestamp)-\(UUID().uuidString.prefix(8)).md"
        let url = base.appending(path: filename)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let cleanedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let metadata = RevisionMetadata(
            createdAt: createdAt,
            name: cleanedName?.isEmpty == false ? cleanedName : nil
        )
        let metadataURL = url.deletingPathExtension().appendingPathExtension("json")
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
        return url
    }

    func revisionText(_ revision: Revision) throws -> String {
        try String(contentsOf: revision.url, encoding: .utf8)
    }

    func revisions(for document: NoteDocument) -> [Revision] {
        guard let base = try? revisionDirectory(
            for: document,
            migrateLegacy: true
        ) else { return [] }
        let urls = (try? fileManager.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "md" else { return nil }
            let metadataURL = url.deletingPathExtension().appendingPathExtension("json")
            let metadata: RevisionMetadata?
            if let data = try? Data(contentsOf: metadataURL) {
                metadata = try? JSONDecoder().decode(RevisionMetadata.self, from: data)
            } else {
                metadata = nil
            }
            let createdAt = metadata?.createdAt
                ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? .distantPast
            return Revision(url: url, createdAt: createdAt, name: metadata?.name)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func migrateRevisions(
        from document: NoteDocument,
        to destinationURL: URL
    ) throws {
        let destinationKey = destinationURL.standardizedFileURL.path
        guard document.persistenceKey != destinationKey else { return }
        let source = try revisionDirectory(for: document, migrateLegacy: true)
        guard fileManager.fileExists(atPath: source.path) else { return }

        let destination = try versionsDirectory().appending(
            path: safeFilename(destinationKey),
            directoryHint: .isDirectory
        )
        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.moveItem(at: source, to: destination)
            return
        }
        try mergeRevisionDirectory(source, into: destination)
    }

    private func nearestHeading(in document: NoteDocument, before line: Int) -> String? {
        searchIndex.heading(in: document, before: line) { document in
            cachedOrRead(document)
        }
    }

    private func cachedOrRead(_ document: NoteDocument) -> String? {
        if let cached = contentCache.get(document) {
            return cached
        }
        guard let content = try? read(document) else { return nil }
        contentCache.set(document, content)
        return content
    }

    private func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return String(path.dropFirst(min(path.count, rootPath.count + 1)))
    }

    private func cleanedFilename(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    private func ensureDestinationIsAvailable(_ destination: URL) throws {
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
    }

    private func ensureContained(_ url: URL, in root: URL) throws {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private func safeFilename(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
    }

    private func versionsDirectory() throws -> URL {
        try applicationSupportDirectory().appending(
            path: "Versions",
            directoryHint: .isDirectory
        )
    }

    private func revisionDirectory(
        for document: NoteDocument,
        migrateLegacy: Bool
    ) throws -> URL {
        let versions = try versionsDirectory()
        let current = versions.appending(
            path: safeFilename(document.persistenceKey),
            directoryHint: .isDirectory
        )
        guard migrateLegacy else { return current }

        let legacy = versions.appending(
            path: safeFilename(document.relativePath),
            directoryHint: .isDirectory
        )
        guard legacy.standardizedFileURL != current.standardizedFileURL,
              fileManager.fileExists(atPath: legacy.path) else {
            return current
        }
        if fileManager.fileExists(atPath: current.path) {
            try mergeRevisionDirectory(legacy, into: current)
        } else {
            try fileManager.createDirectory(at: versions, withIntermediateDirectories: true)
            try fileManager.moveItem(at: legacy, to: current)
        }
        return current
    }

    private func mergeRevisionDirectory(_ source: URL, into destination: URL) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let entries = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil
        )
        let groups = Dictionary(grouping: entries) {
            $0.deletingPathExtension().lastPathComponent
        }
        for (stem, files) in groups {
            let hasCollision = files.contains { file in
                fileManager.fileExists(atPath: destination.appending(
                    path: stem
                ).appendingPathExtension(file.pathExtension).path)
            }
            let targetStem = hasCollision ? "\(UUID().uuidString)-\(stem)" : stem
            for file in files {
                let target = destination.appending(path: targetStem)
                    .appendingPathExtension(file.pathExtension)
                try fileManager.moveItem(at: file, to: target)
            }
        }
        try fileManager.removeItem(at: source)
    }

    private struct RevisionMetadata: Codable {
        let createdAt: Date
        let name: String?
    }

    private func applicationSupportDirectory() throws -> URL {
        if let supportDirectoryOverride {
            try fileManager.createDirectory(
                at: supportDirectoryOverride,
                withIntermediateDirectories: true
            )
            return supportDirectoryOverride
        }
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appending(path: "知境", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Content cache

    private final class ContentCache: @unchecked Sendable {
        private struct Entry {
            let modifiedAt: TimeInterval
            let size: Int
            let text: String

            init(document: NoteDocument, text: String) {
                modifiedAt = document.modifiedAt.timeIntervalSinceReferenceDate
                size = document.size
                self.text = text
            }

            func matches(_ document: NoteDocument) -> Bool {
                modifiedAt == document.modifiedAt.timeIntervalSinceReferenceDate &&
                    size == document.size
            }
        }

        private var storage: [String: Entry] = [:]
        private let lock = NSLock()

        func get(_ document: NoteDocument) -> String? {
            lock.lock(); defer { lock.unlock() }
            let key = Self.key(for: document)
            guard let entry = storage[key] else { return nil }
            guard entry.matches(document) else {
                storage[key] = nil
                return nil
            }
            return entry.text
        }

        func set(_ document: NoteDocument, _ value: String) {
            lock.lock(); defer { lock.unlock() }
            storage[Self.key(for: document)] = Entry(document: document, text: value)
        }

        func remove(_ document: NoteDocument) {
            lock.lock(); defer { lock.unlock() }
            storage[Self.key(for: document)] = nil
        }

        func reconcile(_ documents: [NoteDocument]) {
            let validKeys = Set(documents.map(Self.key(for:)))
            lock.lock(); defer { lock.unlock() }
            storage = storage.filter { validKeys.contains($0.key) }
        }

        private static func key(for document: NoteDocument) -> String {
            document.url.standardizedFileURL.path
        }
    }
}
