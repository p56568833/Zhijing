import Foundation

struct KnowledgeBaseService {
    private var fileManager: FileManager { .default }
    private let allowedExtensions: Set<String> = ["md", "markdown", "txt"]
    private let contentCache = ContentCache()

    func scan(root: URL, excludedFolders: [String]) throws -> [NoteDocument] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .contentModificationDateKey,
            .fileSizeKey, .isHiddenKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var notes: [NoteDocument] = []
        for case let url as URL in enumerator {
            let relative = relativePath(of: url, root: root)
            let components = relative.split(separator: "/").map(String.init)
            if components.contains(where: { excludedFolders.contains($0) }) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true,
                  allowedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            notes.append(NoteDocument(
                url: url,
                relativePath: relative,
                modifiedAt: values.contentModificationDate ?? .distantPast,
                size: values.fileSize ?? 0
            ))
        }
        return notes.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    func read(_ document: NoteDocument) throws -> String {
        try String(contentsOf: document.url, encoding: .utf8)
    }

    func write(_ text: String, to document: NoteDocument) throws {
        try text.write(to: document.url, atomically: true, encoding: .utf8)
        contentCache.set(document.relativePath, text)
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
        let cleaned = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !cleaned.isEmpty else { return document.url }
        let ext = document.url.pathExtension
        let filename = cleaned.hasSuffix(".\(ext)") ? cleaned : "\(cleaned).\(ext)"
        let destination = document.url.deletingLastPathComponent().appending(path: filename)
        guard destination.standardizedFileURL != document.url.standardizedFileURL else {
            return document.url
        }
        try fileManager.moveItem(at: document.url, to: destination)
        contentCache.remove(document.relativePath)
        return destination
    }

    func trash(_ document: NoteDocument) throws {
        try fileManager.trashItem(at: document.url, resultingItemURL: nil)
        contentCache.remove(document.relativePath)
    }

    func search(
        query: String,
        documents: [NoteDocument],
        currentFolder: String? = nil,
        limit: Int = 60
    ) -> [SearchHit] {
        let terms = tokenize(query)
        guard !terms.isEmpty else { return [] }
        let candidates = currentFolder.map { folder in
            documents.filter { $0.folder == folder || $0.folder.hasPrefix(folder + "/") }
        } ?? documents

        var hits: [SearchHit] = []
        for document in candidates {
            let content: String
            if let cached = contentCache.get(document.relativePath) {
                content = cached
            } else if let read = try? read(document) {
                content = read
                contentCache.set(document.relativePath, content)
            } else {
                continue
            }
            let lines = content.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let bodyScore = matchScore(terms: terms, in: line)
                let titleScore = matchScore(terms: terms, in: document.title) * 2.4
                let score = bodyScore + titleScore
                guard score > 0 else { continue }
                let lower = max(0, index - 1)
                let upper = min(lines.count, index + 2)
                let excerpt = lines[lower..<upper].joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                hits.append(SearchHit(
                    document: document,
                    excerpt: excerpt,
                    line: index + 1,
                    score: score
                ))
            }
        }
        return hits.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
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

    func createSnapshot(text: String, document: NoteDocument) throws -> URL {
        let base = try applicationSupportDirectory().appending(
            path: "Versions/\(safeFilename(document.relativePath))",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let filename = formatter.string(from: .now).replacingOccurrences(of: ":", with: "-") + ".md"
        let url = base.appending(path: filename)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func revisions(for document: NoteDocument) -> [Revision] {
        guard let base = try? applicationSupportDirectory().appending(
            path: "Versions/\(safeFilename(document.relativePath))",
            directoryHint: .isDirectory
        ) else { return [] }
        let urls = (try? fileManager.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url in
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return Revision(url: url, createdAt: date)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private func nearestHeading(in document: NoteDocument, before line: Int) -> String? {
        guard let content = try? read(document) else { return nil }
        let lines = content.components(separatedBy: .newlines)
        for value in lines.prefix(max(0, line)).reversed() where value.hasPrefix("#") {
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        }
        return nil
    }

    private func tokenize(_ value: String) -> [String] {
        let components = value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return components.flatMap { component in
            let characters = Array(component)
            let containsCJK = characters.contains { character in
                character.unicodeScalars.contains {
                    (0x4E00...0x9FFF).contains(Int($0.value))
                }
            }
            guard containsCJK, characters.count > 2 else { return [component] }
            return (0..<(characters.count - 1)).map {
                String(characters[$0...($0 + 1)])
            }
        }
    }

    private func matchScore(terms: [String], in value: String) -> Double {
        let lower = value.lowercased()
        return terms.reduce(0) { result, term in
            result + (lower.localizedStandardContains(term) ? 1 : 0)
        }
    }

    private func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return String(path.dropFirst(min(path.count, rootPath.count + 1)))
    }

    private func safeFilename(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
    }

    private func applicationSupportDirectory() throws -> URL {
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
        private var storage: [String: String] = [:]
        private let lock = NSLock()

        func get(_ key: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return storage[key]
        }

        func set(_ key: String, _ value: String) {
            lock.lock(); defer { lock.unlock() }
            storage[key] = value
        }

        func remove(_ key: String) {
            lock.lock(); defer { lock.unlock() }
            storage[key] = nil
        }
    }
}
