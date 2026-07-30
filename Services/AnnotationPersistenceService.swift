import Foundation

final class AnnotationPersistenceService: @unchecked Sendable {
    static let portableFilename = "ZHJING_COMMENTS.md"
    static let externalSidecarSuffix = ".zhijing-comments.md"

    static func isPersistenceFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name == portableFilename || name.hasSuffix(externalSidecarSuffix)
    }

    private static let dataStart = "<!-- ZHIJING_DATA_BEGIN -->"
    private static let dataEnd = "<!-- ZHIJING_DATA_END -->"

    private struct PortableStore: Codable {
        let version: Int
        let documents: [String: [TextAnnotation]]
    }

    private let directoryOverride: URL?
    private let queue = DispatchQueue(
        label: "com.zhijing.annotation-persistence",
        qos: .utility
    )
    private let lock = NSLock()
    private var pendingAnnotations: [String: [TextAnnotation]]?
    private var pendingPortableWrites: [String: (URL, [String: [TextAnnotation]])] = [:]
    private var workerScheduled = false
    private var lastError: Error?

    init(directoryOverride: URL? = nil) {
        self.directoryOverride = directoryOverride
    }

    func load() -> [String: [TextAnnotation]] {
        (try? loadStrict()) ?? [:]
    }

    func loadStrict() throws -> [String: [TextAnnotation]] {
        let url = try storageURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(
            [String: [TextAnnotation]].self,
            from: data
        )
    }

    func loadLibrary(at root: URL) throws -> [String: [TextAnnotation]] {
        let url = root.appending(path: Self.portableFilename)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let portable = try decodePortableFile(at: url)
        return Dictionary(uniqueKeysWithValues: portable.documents.map { relative, items in
            let absolute = root.appending(path: relative).standardizedFileURL.path
            return (absolute, items)
        })
    }

    func loadExternal(document: NoteDocument) throws -> [TextAnnotation]? {
        let url = sidecarURL(for: document)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let portable = try decodePortableFile(at: url)
        return portable.documents[document.url.lastPathComponent]
            ?? portable.documents.values.first
            ?? []
    }

    func save(_ annotations: [String: [TextAnnotation]]) {
        enqueue(annotations: annotations, portableWrite: nil)
    }

    func saveLibrary(
        _ annotations: [String: [TextAnnotation]],
        at root: URL
    ) {
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath + "/"
        let pairs: [(String, [TextAnnotation])] = annotations.compactMap { key, items in
            guard key.hasPrefix(prefix), !items.isEmpty else { return nil }
            return (String(key.dropFirst(prefix.count)), items)
        }
        let portable = Dictionary(uniqueKeysWithValues: pairs)
        let url = root.appending(path: Self.portableFilename)
        enqueue(annotations: nil, portableWrite: (url, portable))
    }

    func saveExternal(
        _ annotations: [TextAnnotation],
        document: NoteDocument
    ) {
        let value = annotations.isEmpty
            ? [:]
            : [document.url.lastPathComponent: annotations]
        enqueue(
            annotations: nil,
            portableWrite: (sidecarURL(for: document), value)
        )
    }

    func saveSynchronously(
        _ annotations: [String: [TextAnnotation]],
        libraryRoot: URL? = nil,
        externalDocuments: [NoteDocument] = []
    ) throws {
        save(annotations)
        if let libraryRoot {
            saveLibrary(annotations, at: libraryRoot)
        }
        for document in externalDocuments {
            saveExternal(
                annotations[document.persistenceKey] ?? [],
                document: document
            )
        }
        queue.sync {}
        lock.lock(); defer { lock.unlock() }
        if let lastError { throw lastError }
    }

    private func enqueue(
        annotations: [String: [TextAnnotation]]?,
        portableWrite: (URL, [String: [TextAnnotation]])?
    ) {
        lock.lock()
        if let annotations {
            pendingAnnotations = annotations
        }
        if let portableWrite {
            pendingPortableWrites[portableWrite.0.standardizedFileURL.path] = portableWrite
        }
        guard !workerScheduled else {
            lock.unlock()
            return
        }
        workerScheduled = true
        lock.unlock()

        queue.async { [weak self] in
            self?.drainPendingSaves()
        }
    }

    private func drainPendingSaves() {
        while true {
            lock.lock()
            let annotations = pendingAnnotations
            let portableWrites = Array(pendingPortableWrites.values)
            pendingAnnotations = nil
            pendingPortableWrites.removeAll()
            if annotations == nil, portableWrites.isEmpty {
                workerScheduled = false
                lock.unlock()
                return
            }
            lock.unlock()

            do {
                if let annotations {
                    try writeLegacyCache(annotations)
                }
                for (url, documents) in portableWrites {
                    try writePortable(documents: documents, to: url)
                }
                lock.lock()
                lastError = nil
                lock.unlock()
            } catch {
                lock.lock()
                lastError = error
                lock.unlock()
            }
        }
    }

    private func writeLegacyCache(
        _ annotations: [String: [TextAnnotation]]
    ) throws {
        let url = try storageURL()
        let existingData: Data?
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            _ = try JSONDecoder().decode(
                [String: [TextAnnotation]].self,
                from: data
            )
            existingData = data
        } else {
            existingData = nil
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(annotations)
        guard data != existingData else { return }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func writePortable(
        documents: [String: [TextAnnotation]],
        to url: URL
    ) throws {
        let existingText: String?
        if FileManager.default.fileExists(atPath: url.path) {
            let text = try String(contentsOf: url, encoding: .utf8)
            _ = try decodePortableText(text)
            existingText = text
        } else {
            guard !documents.isEmpty else { return }
            existingText = nil
        }

        let store = PortableStore(version: 1, documents: documents)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(store)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        let rendered = renderPortableMarkdown(documents: documents, json: json)
        guard rendered != existingText else { return }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try rendered.write(to: url, atomically: true, encoding: .utf8)
    }

    private func decodePortableFile(at url: URL) throws -> PortableStore {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try decodePortableText(text)
    }

    private func decodePortableText(_ text: String) throws -> PortableStore {
        guard let start = text.range(of: Self.dataStart),
              let end = text.range(
                  of: Self.dataEnd,
                  range: start.upperBound..<text.endIndex
              ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var payload = String(text[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.hasPrefix("```json") {
            payload.removeFirst("```json".count)
        }
        if payload.hasSuffix("```") {
            payload.removeLast(3)
        }
        guard let data = payload
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .data(using: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let decoder = JSONDecoder()
        return try decoder.decode(PortableStore.self, from: data)
    }

    private func renderPortableMarkdown(
        documents: [String: [TextAnnotation]],
        json: String
    ) -> String {
        var sections = [
            "# 知境批注索引",
            "",
            "> 给外部 AI：阅读、修改或评审下列文稿时，必须同时读取对应批注。批注代表用户的判断、问题和修改意图，不是正文事实或引用来源。",
            ""
        ]
        for path in documents.keys.sorted() {
            guard let items = documents[path], !items.isEmpty else { continue }
            sections.append("## `\(path)`")
            sections.append("")
            for (index, annotation) in items.sorted(by: {
                $0.anchor.utf16Location < $1.anchor.utf16Location
            }).enumerated() {
                sections.append("### 批注 \(index + 1)")
                sections.append("")
                sections.append("**对应原文**")
                sections.append("")
                sections.append(contentsOf: blockquote(annotation.anchor.selectedText))
                sections.append("")
                sections.append("**用户批注**")
                sections.append("")
                sections.append(annotation.text)
                sections.append("")
                sections.append("**状态**：\(annotation.isResolved ? "已处理" : "待处理")")
                sections.append("")
            }
        }
        sections.append("---")
        sections.append("")
        sections.append("以下是知境用于稳定定位批注的结构化数据，请勿手动修改：")
        sections.append("")
        sections.append(Self.dataStart)
        sections.append("```json")
        sections.append(json)
        sections.append("```")
        sections.append(Self.dataEnd)
        sections.append("")
        return sections.joined(separator: "\n")
    }

    private func blockquote(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { line in
            "> \(line)"
        }
    }

    private func sidecarURL(for document: NoteDocument) -> URL {
        document.url.appendingPathExtension("zhijing-comments.md")
    }

    private func storageURL() throws -> URL {
        if let directoryOverride {
            return directoryOverride.appending(path: "Annotations.json")
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appending(path: "知境/Annotations.json")
    }
}
