import Foundation

struct DocumentOutlineItem: Identifiable, Equatable, Sendable {
    let title: String
    let level: Int
    let line: Int

    var id: String { "\(line):\(level):\(title)" }
}

enum DocumentOutlineParser {
    static func parse(_ markdown: String) -> [DocumentOutlineItem] {
        let lines = markdown.components(separatedBy: .newlines)
        var result: [DocumentOutlineItem] = []
        var isInsideFence = false

        for (offset, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                isInsideFence.toggle()
                continue
            }
            guard !isInsideFence else { continue }

            if let heading = atxHeading(in: trimmed) {
                result.append(DocumentOutlineItem(
                    title: heading.title,
                    level: heading.level,
                    line: offset + 1
                ))
                continue
            }

            guard offset > 0,
                  let level = setextLevel(for: trimmed) else { continue }
            let title = lines[offset - 1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty,
                  atxHeading(in: title) == nil else { continue }
            result.append(DocumentOutlineItem(
                title: cleanedTitle(title),
                level: level,
                line: offset
            ))
        }

        return result
    }

    private static func atxHeading(
        in line: String
    ) -> (title: String, level: Int)? {
        let characters = Array(line)
        let level = characters.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level),
              characters.count > level,
              characters[level].isWhitespace else { return nil }
        let title = String(characters.dropFirst(level))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"\s+#+\s*$"#,
                with: "",
                options: .regularExpression
            )
        guard !title.isEmpty else { return nil }
        return (cleanedTitle(title), level)
    }

    private static func setextLevel(for line: String) -> Int? {
        guard line.count >= 3 else { return nil }
        if line.allSatisfy({ $0 == "=" }) { return 1 }
        if line.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private static func cleanedTitle(_ title: String) -> String {
        InlineTextMarkMarkdown.removingSyntax(from: title)
            .replacingOccurrences(of: #"[*_`]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
