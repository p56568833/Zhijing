import Foundation

struct DocumentMetrics: Equatable, Sendable {
    let count: Int
    let estimatedSpeakingSeconds: Double
    private static let linkExpression = try? NSRegularExpression(
        pattern: #"\[([^\]]+)\]\([^)]+\)"#
    )
    private static let blockMarkerExpression = try? NSRegularExpression(
        pattern: #"(?m)^\s{0,3}(#{1,6}\s+|>\s?|[-+*]\s+|\d+[.)]\s+)"#
    )
    private static let emphasisExpression = try? NSRegularExpression(
        pattern: #"[`*_~]"#
    )

    init(markdown: String) {
        let plainText = Self.plainText(from: markdown)
        let cjkCount = plainText.reduce(into: 0) { count, character in
            if character.unicodeScalars.contains(where: Self.isCJK) {
                count += 1
            }
        }
        let latinWordCount = plainText
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { token in
                !token.isEmpty && !token.unicodeScalars.contains(where: Self.isCJK)
            }
            .count
        count = cjkCount + latinWordCount
        estimatedSpeakingSeconds =
            (Double(cjkCount) / 250 * 60) +
            (Double(latinWordCount) / 150 * 60)
    }

    var countLabel: String {
        "\(count.formatted()) 字"
    }

    var speakingDurationLabel: String {
        guard count > 0 else { return "0 分钟" }
        guard estimatedSpeakingSeconds >= 60 else { return "不足 1 分钟" }
        let minutes = max(1, Int((estimatedSpeakingSeconds / 60).rounded()))
        return "约 \(minutes.formatted()) 分钟"
    }

    private static func plainText(from markdown: String) -> String {
        var text = InlineTextMarkMarkdown.removingSyntax(from: markdown)
        text = replacing(
            linkExpression,
            in: text,
            with: "$1"
        )
        text = replacing(
            blockMarkerExpression,
            in: text,
            with: ""
        )
        text = replacing(
            emphasisExpression,
            in: text,
            with: ""
        )
        return text
    }

    private static func replacing(
        _ expression: NSRegularExpression?,
        in text: String,
        with template: String
    ) -> String {
        guard let expression else { return text }
        return expression.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: template
        )
    }

    private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            true
        default:
            false
        }
    }
}
