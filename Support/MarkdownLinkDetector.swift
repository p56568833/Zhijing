import Foundation

struct MarkdownEditorLink: Equatable, Sendable {
    let range: NSRange
    let url: URL
}

enum MarkdownLinkDetector {
    private static let expression = try? NSRegularExpression(
        pattern: #"\[[^\]\n]+\]\(([^)]+)\)"#
    )

    static func links(
        in source: String,
        characterRange requestedRange: NSRange? = nil
    ) -> [MarkdownEditorLink] {
        guard let expression else { return [] }
        let nsSource = source as NSString
        let fullRange = NSRange(location: 0, length: nsSource.length)
        let searchRange = requestedRange.map {
            NSIntersectionRange($0, fullRange)
        } ?? fullRange
        return expression.matches(
            in: source,
            range: searchRange
        ).compactMap { match in
            guard match.numberOfRanges >= 2 else { return nil }
            let target = nsSource.substring(with: match.range(at: 1))
            guard let url = URL(string: target) ?? URL(string: "https://\(target)") else {
                return nil
            }
            return MarkdownEditorLink(range: match.range, url: url)
        }
    }
}
