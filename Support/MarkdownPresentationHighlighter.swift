import AppKit

enum MarkdownFenceStateResolver {
    static func isInsideFence(before location: Int, in source: String) -> Bool {
        guard location > 0 else { return false }
        let nsSource = source as NSString
        let prefix = nsSource.substring(
            with: NSRange(location: 0, length: min(location, nsSource.length))
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

enum MarkdownPresentationStyle {
    case heading
    case quote
    case annotationHeader
    case annotationContext
    case annotationBody
    case horizontalRule
    case fence
    case codeBlock
    case inlineCode
    case strong
    case listMarker
    case link
    case textHighlight
    case textImportant
    case textConcept
    case textUnderline
    case textRed
    case textOrange
    case textGreen
    case textBlue
    case textMarkSyntax

    var attributes: [NSAttributedString.Key: Any] {
        switch self {
        case .heading:
            [
                .foregroundColor: ZhijingTheme.accentNSColor,
                .backgroundColor: ZhijingTheme.accentNSColor.withAlphaComponent(0.055)
            ]
        case .quote:
            [.foregroundColor: ZhijingTheme.quoteNSColor]
        case .annotationHeader:
            [
                .foregroundColor: ZhijingTheme.annotationNSColor,
                .backgroundColor: ZhijingTheme.annotationNSColor.withAlphaComponent(0.08)
            ]
        case .annotationContext:
            [
                .foregroundColor: NSColor.secondaryLabelColor,
                .backgroundColor: ZhijingTheme.annotationNSColor.withAlphaComponent(0.035)
            ]
        case .annotationBody:
            [
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: ZhijingTheme.annotationNSColor.withAlphaComponent(0.035)
            ]
        case .horizontalRule:
            [
                .foregroundColor: NSColor.secondaryLabelColor,
                .underlineStyle: NSUnderlineStyle.thick.rawValue
            ]
        case .fence:
            [
                .foregroundColor: ZhijingTheme.codeNSColor,
                .backgroundColor: ZhijingTheme.codeNSColor.withAlphaComponent(0.075)
            ]
        case .codeBlock:
            [
                .foregroundColor: ZhijingTheme.codeNSColor,
                .backgroundColor: ZhijingTheme.chromeNSColor.withAlphaComponent(0.72)
            ]
        case .inlineCode:
            [
                .foregroundColor: ZhijingTheme.codeNSColor,
                .backgroundColor: ZhijingTheme.codeNSColor.withAlphaComponent(0.075)
            ]
        case .strong:
            [.foregroundColor: ZhijingTheme.accentNSColor]
        case .listMarker:
            [.foregroundColor: ZhijingTheme.annotationNSColor]
        case .link:
            [
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        case .textHighlight:
            [
                .backgroundColor: ZhijingTheme.highlightNSColor
                    .withAlphaComponent(0.32)
            ]
        case .textImportant:
            [.foregroundColor: ZhijingTheme.importantNSColor]
        case .textConcept:
            [.foregroundColor: ZhijingTheme.conceptNSColor]
        case .textUnderline:
            [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: ZhijingTheme.underlineNSColor
            ]
        case .textRed:
            [.foregroundColor: NSColor.systemRed]
        case .textOrange:
            [.foregroundColor: NSColor.systemOrange]
        case .textGreen:
            [.foregroundColor: NSColor.systemGreen]
        case .textBlue:
            [.foregroundColor: NSColor.systemBlue]
        case .textMarkSyntax:
            [.foregroundColor: NSColor.tertiaryLabelColor]
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
        .underlineStyle,
        .underlineColor
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
        characterRange requestedRange: NSRange? = nil,
        startsInsideFence resolvedFenceState: Bool? = nil
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
            startsInsideFence = resolvedFenceState
                ?? MarkdownFenceStateResolver.isInsideFence(
                    before: stylingRange.location,
                    in: textView.string
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
        var inAnnotation = false
        var annotationBodyStarted = false
        var inlineExcludedRanges: [NSRange] = []

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
                inlineExcludedRanges.append(contentRange)
                inFence.toggle()
                inAnnotation = false
                annotationBodyStarted = false
            } else if inFence {
                result.append(.init(range: contentRange, style: .codeBlock))
                inlineExcludedRanges.append(contentRange)
            } else if InlineAnnotationMarkdown.isHeading(trimmed) {
                result.append(.init(range: contentRange, style: .annotationHeader))
                inAnnotation = true
                annotationBodyStarted = false
            } else if inAnnotation, trimmed.hasPrefix(">") {
                let quotedContent = String(trimmed.dropFirst())
                    .trimmingCharacters(in: .whitespaces)
                if quotedContent.isEmpty {
                    annotationBodyStarted = true
                }
                result.append(.init(
                    range: contentRange,
                    style: annotationBodyStarted
                        ? .annotationBody
                        : .annotationContext
                ))
            } else if trimmed.isEmpty {
                inAnnotation = false
                annotationBodyStarted = false
            } else if firstMatch(headingExpression, in: line) != nil {
                inAnnotation = false
                annotationBodyStarted = false
                result.append(.init(range: contentRange, style: .heading))
            } else if firstMatch(quoteExpression, in: line) != nil {
                inAnnotation = false
                result.append(.init(range: contentRange, style: .quote))
            } else if firstMatch(horizontalRuleExpression, in: line) != nil {
                inAnnotation = false
                result.append(.init(range: contentRange, style: .horizontalRule))
            } else if let marker = firstMatch(
                listMarkerExpression,
                in: line
            ) {
                inAnnotation = false
                result.append(.init(
                    range: NSRange(
                        location: contentRange.location + marker.range.location,
                        length: marker.range.length
                    ),
                    style: .listMarker
                ))
            } else if !trimmed.isEmpty {
                inAnnotation = false
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
        for mark in InlineTextMarkMarkdown.spans(
            in: source,
            baseLocation: baseLocation
        ) where inlineExcludedRanges.allSatisfy({
            NSIntersectionRange($0, mark.fullRange).length == 0
        }) {
            result.append(.init(
                range: mark.contentRange,
                style: presentationStyle(for: mark.kind)
            ))
            result.append(.init(range: mark.prefixRange, style: .textMarkSyntax))
            result.append(.init(range: mark.suffixRange, style: .textMarkSyntax))
        }
        for link in links ?? MarkdownLinkDetector.links(in: source) {
            result.append(.init(range: link.range, style: .link))
        }
        return result
    }

    private static func presentationStyle(
        for kind: InlineTextMarkKind
    ) -> MarkdownPresentationStyle {
        switch kind {
        case .highlight: .textHighlight
        case .important: .textImportant
        case .concept: .textConcept
        case .underline: .textUnderline
        case .red: .textRed
        case .orange: .textOrange
        case .green: .textGreen
        case .blue: .textBlue
        }
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

}
