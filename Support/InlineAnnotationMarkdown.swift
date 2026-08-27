import Foundation

struct InlineAnnotationInsertion: Equatable, Sendable {
    let range: NSRange
    let replacementText: String
    let cursorLocation: Int
}

enum InlineAnnotationMarkdown {
    static let heading = "> 批注"
    static let legacyHeading = "> **批注**"

    static func isHeading(_ line: String) -> Bool {
        line == heading || line == legacyHeading
    }

    static func insertion(
        in source: String,
        selection: NSRange,
        annotation: String
    ) -> InlineAnnotationInsertion? {
        let nsSource = source as NSString
        let value = annotation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              selection.length > 0,
              NSMaxRange(selection) <= nsSource.length else { return nil }

        let selectedText = nsSource.substring(with: selection)
        let lastSelectedLocation = max(selection.location, NSMaxRange(selection) - 1)
        let selectedLineRange = nsSource.lineRange(
            for: NSRange(location: lastSelectedLocation, length: 0)
        )
        let insertionLocation = NSMaxRange(selectedLineRange)
        let block = render(annotation: value, selectedText: selectedText)

        let hasLeadingNewline = insertionLocation > 0
            && nsSource.character(at: insertionLocation - 1) == 10
        let hasFollowingContent = insertionLocation < nsSource.length
        let leading = hasLeadingNewline ? "\n" : "\n\n"
        let trailing = hasFollowingContent ? "\n\n" : "\n"
        let replacement = leading + block + trailing

        return InlineAnnotationInsertion(
            range: NSRange(location: insertionLocation, length: 0),
            replacementText: replacement,
            cursorLocation: insertionLocation + (replacement as NSString).length
        )
    }

    static func render(annotation: String, selectedText: String) -> String {
        let excerpt = compactExcerpt(selectedText)
        var lines = [heading, "> 原文 · 「\(excerpt)」", ">"]
        lines.append(contentsOf: annotation
            .components(separatedBy: .newlines)
            .map { $0.isEmpty ? ">" : "> \($0)" })
        return lines.joined(separator: "\n")
    }

    private static func compactExcerpt(_ source: String) -> String {
        let compact = source
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let limit = 80
        guard compact.count > limit else { return compact }
        return String(compact.prefix(limit)) + "…"
    }
}
