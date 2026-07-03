import Foundation

struct MarkdownEditorLink: Equatable {
    let range: NSRange
    let url: URL
}

enum MarkdownLinkDetector {
    private static let expression = try? NSRegularExpression(
        pattern: #"\[[^\]\n]+\]\(([^)]+)\)"#
    )

    static func links(in source: String) -> [MarkdownEditorLink] {
        guard let expression else { return [] }
        let nsSource = source as NSString
        return expression.matches(
            in: source,
            range: NSRange(location: 0, length: nsSource.length)
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
