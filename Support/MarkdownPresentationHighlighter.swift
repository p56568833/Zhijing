import AppKit

enum MarkdownPresentationStyle {
    case heading
    case quote
    case horizontalRule
    case fence
    case codeBlock
    case inlineCode
    case strong
    case listMarker
    case link

    var attributes: [NSAttributedString.Key: Any] {
        switch self {
        case .heading:
            [
                .foregroundColor: NSColor.systemBlue,
                .backgroundColor: NSColor.systemBlue.withAlphaComponent(0.06)
            ]
        case .quote:
            [.foregroundColor: NSColor.systemGreen]
        case .horizontalRule:
            [
                .foregroundColor: NSColor.secondaryLabelColor,
                .underlineStyle: NSUnderlineStyle.thick.rawValue
            ]
        case .fence:
            [
                .foregroundColor: NSColor.systemPurple,
                .backgroundColor: NSColor.systemPurple.withAlphaComponent(0.08)
            ]
        case .codeBlock:
            [
                .foregroundColor: NSColor.systemTeal,
                .backgroundColor: NSColor.controlBackgroundColor.withAlphaComponent(0.7)
            ]
        case .inlineCode:
            [
                .foregroundColor: NSColor.systemPurple,
                .backgroundColor: NSColor.systemPurple.withAlphaComponent(0.08)
            ]
        case .strong:
            [.foregroundColor: NSColor.systemIndigo]
        case .listMarker:
            [.foregroundColor: NSColor.systemOrange]
        case .link:
            [
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        }
    }
}

struct MarkdownPresentationSpan {
    let range: NSRange
    let style: MarkdownPresentationStyle
}

@MainActor
enum MarkdownPresentationHighlighter {
    private static let temporaryKeys: [NSAttributedString.Key] = [
        .foregroundColor,
        .backgroundColor,
        .underlineStyle
    ]

    static func apply(to textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        let fullRange = NSRange(location: 0, length: textView.string.utf16.count)
        for key in temporaryKeys {
            layoutManager.removeTemporaryAttribute(key, forCharacterRange: fullRange)
        }
        for span in spans(in: textView.string) where span.range.length > 0 {
            layoutManager.addTemporaryAttributes(
                span.style.attributes,
                forCharacterRange: span.range
            )
        }
    }

    static func spans(in source: String) -> [MarkdownPresentationSpan] {
        let string = source as NSString
        var result: [MarkdownPresentationSpan] = []
        var location = 0
        var inFence = false

        while location < string.length {
            let lineRange = string.lineRange(
                for: NSRange(location: location, length: 0)
            )
            let line = string.substring(with: lineRange)
                .trimmingCharacters(in: .newlines)
            let contentRange = NSRange(
                location: lineRange.location,
                length: (line as NSString).length
            )
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                result.append(.init(range: contentRange, style: .fence))
                inFence.toggle()
            } else if inFence {
                result.append(.init(range: contentRange, style: .codeBlock))
            } else if firstMatch(#"^\s*#{1,6}\s+"#, in: line) != nil {
                result.append(.init(range: contentRange, style: .heading))
            } else if firstMatch(#"^\s*>\s?"#, in: line) != nil {
                result.append(.init(range: contentRange, style: .quote))
            } else if firstMatch(
                #"^\s*((-{3,})|(\*{3,})|(_{3,}))\s*$"#,
                in: line
            ) != nil {
                result.append(.init(range: contentRange, style: .horizontalRule))
            } else if let marker = firstMatch(
                #"^\s*([-+*]|\d+[.)])(?=\s)"#,
                in: line
            ) {
                result.append(.init(
                    range: NSRange(
                        location: contentRange.location + marker.range.location,
                        length: marker.range.length
                    ),
                    style: .listMarker
                ))
            }
            location = NSMaxRange(lineRange)
        }

        addMatches(#"`[^`\n]+`"#, style: .inlineCode, source: source, to: &result)
        addMatches(
            #"\*\*[^*\n]+\*\*|__[^_\n]+__"#,
            style: .strong,
            source: source,
            to: &result
        )
        for link in MarkdownLinkDetector.links(in: source) {
            result.append(.init(range: link.range, style: .link))
        }
        return result
    }

    private static func addMatches(
        _ pattern: String,
        style: MarkdownPresentationStyle,
        source: String,
        to result: inout [MarkdownPresentationSpan]
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return
        }
        let range = NSRange(location: 0, length: (source as NSString).length)
        for match in expression.matches(in: source, range: range) {
            result.append(.init(range: match.range, style: style))
        }
    }

    private static func firstMatch(
        _ pattern: String,
        in source: String
    ) -> NSTextCheckingResult? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        return expression.firstMatch(
            in: source,
            range: NSRange(location: 0, length: (source as NSString).length)
        )
    }
}
