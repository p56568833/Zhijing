import Foundation

final class KnowledgeSearchIndex: @unchecked Sendable {
    private struct Signature: Equatable {
        let modifiedAt: TimeInterval
        let size: Int
    }

    private struct LineKey: Hashable {
        let path: String
        let line: Int
    }

    private struct IndexedLine {
        let number: Int
        let excerpt: String
        let terms: Set<String>
    }

    private struct IndexedDocument {
        let signature: Signature
        let title: String
        let titleTerms: Set<String>
        let lines: [IndexedLine]
        let headings: [(line: Int, title: String)]
    }

    private let lock = NSLock()
    private var documents: [String: IndexedDocument] = [:]
    private var inverted: [String: Set<LineKey>] = [:]

    func invalidate(_ relativePath: String) {
        lock.lock()
        defer { lock.unlock() }
        removeLocked(relativePath)
    }

    func search(
        query: String,
        documents candidates: [NoteDocument],
        limit: Int,
        loadContent: (NoteDocument) -> String?
    ) -> [SearchHit] {
        let terms = SearchTokenization.tokenize(query)
        guard !terms.isEmpty else { return [] }

        lock.lock()
        updateLocked(documents: candidates, loadContent: loadContent)

        let allowedPaths = Set(candidates.map(\.relativePath))
        let candidateByPath = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.relativePath, $0) }
        )
        var scores: [LineKey: Double] = [:]

        for term in terms {
            if let postings = inverted[term] {
                for key in postings where allowedPaths.contains(key.path) {
                    scores[key, default: 0] += 1
                }
            }

            for document in candidates {
                guard let indexed = documents[document.relativePath] else { continue }
                if indexed.titleTerms.contains(term) ||
                    indexed.title.localizedStandardContains(term) {
                    scores[LineKey(path: document.relativePath, line: 1), default: 0] += 2.4
                }
            }
        }

        let hits = scores.compactMap { key, score -> SearchHit? in
            guard let document = candidateByPath[key.path],
                  let indexed = documents[key.path],
                  let line = indexed.lines.first(where: { $0.number == key.line })
            else { return nil }
            return SearchHit(
                document: document,
                excerpt: line.excerpt,
                line: line.number,
                score: score
            )
        }
        .sorted {
            if $0.score == $1.score {
                return $0.document.relativePath.localizedStandardCompare(
                    $1.document.relativePath
                ) == .orderedAscending
            }
            return $0.score > $1.score
        }
        .prefix(limit)
        .map { $0 }

        lock.unlock()
        return hits
    }

    func heading(
        in document: NoteDocument,
        before line: Int,
        loadContent: (NoteDocument) -> String?
    ) -> String? {
        lock.lock()
        updateLocked(documents: [document], loadContent: loadContent)
        let heading = documents[document.relativePath]?.headings
            .last { $0.line <= line }?
            .title
        lock.unlock()
        return heading
    }

    private func updateLocked(
        documents candidates: [NoteDocument],
        loadContent: (NoteDocument) -> String?
    ) {
        for document in candidates {
            let signature = Signature(
                modifiedAt: document.modifiedAt.timeIntervalSinceReferenceDate,
                size: document.size
            )
            if documents[document.relativePath]?.signature == signature {
                continue
            }
            guard let content = loadContent(document) else {
                removeLocked(document.relativePath)
                continue
            }
            replaceLocked(
                document: document,
                signature: signature,
                content: content
            )
        }
    }

    private func replaceLocked(
        document: NoteDocument,
        signature: Signature,
        content: String
    ) {
        removeLocked(document.relativePath)

        let rawLines = content.components(separatedBy: .newlines)
        let indexedLines = rawLines.enumerated().map { index, line in
            let lower = max(0, index - 1)
            let upper = min(rawLines.count, index + 2)
            let excerpt = rawLines[lower..<upper].joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return IndexedLine(
                number: index + 1,
                excerpt: excerpt.isEmpty ? line : excerpt,
                terms: Set(SearchTokenization.tokenize(line))
            )
        }
        let headings = rawLines.enumerated().compactMap { index, line -> (Int, String)? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { return nil }
            let title = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            return title.isEmpty ? nil : (index + 1, title)
        }
        documents[document.relativePath] = IndexedDocument(
            signature: signature,
            title: document.title.lowercased(),
            titleTerms: Set(SearchTokenization.tokenize(document.title)),
            lines: indexedLines,
            headings: headings
        )

        for line in indexedLines {
            let key = LineKey(path: document.relativePath, line: line.number)
            for term in line.terms {
                inverted[term, default: []].insert(key)
            }
        }
    }

    private func removeLocked(_ relativePath: String) {
        guard let indexed = documents.removeValue(forKey: relativePath) else { return }
        for line in indexed.lines {
            let key = LineKey(path: relativePath, line: line.number)
            for term in line.terms {
                inverted[term]?.remove(key)
                if inverted[term]?.isEmpty == true {
                    inverted[term] = nil
                }
            }
        }
    }
}

enum SearchTokenization {
    static func tokenize(_ value: String) -> [String] {
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
}
