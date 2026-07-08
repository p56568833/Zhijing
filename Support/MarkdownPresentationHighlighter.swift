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

    private static let headingExpression = expression(#"^\s*#{1,6}\s+"#)
    private static let quoteExpression = expression(#"^\s*>\s?"#)
    private static let horizontalRuleExpression = expression(
        #"^\s*((-{3,})|(\*{3,})|(_{3,}))\s*$"#
    )
    private static let listMarkerExpression = expression(
        #"^\s*([-+*]|\d+[.)])(?=\s)"#
    )
    private static let inlineCodeExpression = expression(#"`[^`\n]+`"#)
    private static let strongExpression = expression(
        #"\*\*[^*\n]+\*\*|__[^_\n]+__"#
    )

    static func apply(
        to textView: NSTextView,
        links: [MarkdownEditorLink]? = nil,
        characterRange requestedRange: NSRange? = nil
    ) {
        guard let layoutManager = textView.layoutManager else { return }
        let fullRange = NSRange(location: 0, length: textView.string.utf16.count)
        let stylingRange: NSRange
        if let requestedRange {
            let safeRange = NSIntersectionRange(requestedRange, fullRange)
            stylingRange = (textView.string as NSString).lineRange(for: safeRange)
        } else {
            stylingRange = fullRange
        }
        for key in temporaryKeys {
            layoutManager.removeTemporaryAttribute(key, forCharacterRange: stylingRange)
        }

        let source: String
        let baseLocation: Int
        let startsInsideFence: Bool
        if stylingRange.location == 0, stylingRange.length == fullRange.length {
            source = textView.string
            baseLocation = 0
            startsInsideFence = false
        } else {
            let nsSource = textView.string as NSString
            source = nsSource.substring(with: stylingRange)
            baseLocation = stylingRange.location
            startsInsideFence = isInsideFence(
                before: stylingRange.location,
                in: nsSource
            )
        }

        let resolvedLinks = links ?? MarkdownLinkDetector.links(in: textView.string)
        let linksInRange = resolvedLinks.filter {
            NSIntersectionRange($0.range, stylingRange).length > 0
        }
        for span in spans(
            in: source,
            baseLocation: baseLocation,
            links: linksInRange,
            startsInsideFence: startsInsideFence
        ) where span.range.length > 0 {
            layoutManager.addTemporaryAttributes(
                span.style.attributes,
                forCharacterRange: span.range
            )
        }
    }

    static func spans(
        in source: String,
        baseLocation: Int = 0,
        links: [MarkdownEditorLink]? = nil,
        startsInsideFence: Bool = false
    ) -> [MarkdownPresentationSpan] {
        let string = source as NSString
        var result: [MarkdownPresentationSpan] = []
        var location = 0
        var inFence = startsInsideFence

        while location < string.length {
            let lineRange = string.lineRange(
                for: NSRange(location: location, length: 0)
            )
            let line = string.substring(with: lineRange)
                .trimmingCharacters(in: .newlines)
            let contentRange = NSRange(
                location: baseLocation + lineRange.location,
                length: (line as NSString).length
            )
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                result.append(.init(range: contentRange, style: .fence))
                inFence.toggle()
            } else if inFence {
                result.append(.init(range: contentRange, style: .codeBlock))
            } else if firstMatch(headingExpression, in: line) != nil {
                result.append(.init(range: contentRange, style: .heading))
            } else if firstMatch(quoteExpression, in: line) != nil {
                result.append(.init(range: contentRange, style: .quote))
            } else if firstMatch(horizontalRuleExpression, in: line) != nil {
                result.append(.init(range: contentRange, style: .horizontalRule))
            } else if let marker = firstMatch(
                listMarkerExpression,
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

        addMatches(
            inlineCodeExpression,
            style: .inlineCode,
            source: source,
            baseLocation: baseLocation,
            to: &result
        )
        addMatches(
            strongExpression,
            style: .strong,
            source: source,
            baseLocation: baseLocation,
            to: &result
        )
        for link in links ?? MarkdownLinkDetector.links(in: source) {
            result.append(.init(range: link.range, style: .link))
        }
        return result
    }

    private static func addMatches(
        _ expression: NSRegularExpression?,
        style: MarkdownPresentationStyle,
        source: String,
        baseLocation: Int,
        to result: inout [MarkdownPresentationSpan]
    ) {
        guard let expression else { return }
        let range = NSRange(location: 0, length: (source as NSString).length)
        for match in expression.matches(in: source, range: range) {
            result.append(.init(
                range: NSRange(
                    location: baseLocation + match.range.location,
                    length: match.range.length
                ),
                style: style
            ))
        }
    }

    private static func firstMatch(
        _ expression: NSRegularExpression?,
        in source: String
    ) -> NSTextCheckingResult? {
        guard let expression else { return nil }
        return expression.firstMatch(
            in: source,
            range: NSRange(location: 0, length: (source as NSString).length)
        )
    }

    private static func expression(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }

    private static func isInsideFence(before location: Int, in source: NSString) -> Bool {
        guard location > 0 else { return false }
        let prefix = source.substring(
            with: NSRange(location: 0, length: min(location, source.length))
        )
        var inside = false
        for line in prefix.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inside.toggle()
            }
        }
        return inside
    }
}
