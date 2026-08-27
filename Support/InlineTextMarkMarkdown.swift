import AppKit
import Foundation

enum InlineTextMarkKind: String, CaseIterable, Sendable {
    case highlight = "mark"
    case important
    case concept
    case underline

    var title: String {
        switch self {
        case .highlight: "荧光标记"
        case .important: "重要 / 警示"
        case .concept: "概念 / 线索"
        case .underline: "下划线"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .highlight: "黄色荧光背景"
        case .important: "红色重点文字"
        case .concept: "蓝色概念文字"
        case .underline: "保留原色并添加下划线"
        }
    }
}

struct InlineTextMarkSpan: Equatable, Sendable {
    let fullRange: NSRange
    let contentRange: NSRange
    let prefixRange: NSRange
    let suffixRange: NSRange
    let kind: InlineTextMarkKind
}

struct InlineTextMarkMutation: Equatable, Sendable {
    let range: NSRange
    let replacementText: String
    let selectionRange: NSRange
}

enum InlineTextMarkMarkdown {
    static func spans(
        in source: String,
        baseLocation: Int = 0
    ) -> [InlineTextMarkSpan] {
        guard let expression = try? NSRegularExpression(
            pattern: #"\[([^\]\n]+)\]\{\.(mark|important|concept|underline)\}"#
        ) else { return [] }
        let nsSource = source as NSString
        let fullRange = NSRange(location: 0, length: nsSource.length)

        return expression.matches(in: source, range: fullRange).compactMap { match in
            guard match.numberOfRanges == 3,
                  let kind = InlineTextMarkKind(
                    rawValue: nsSource.substring(with: match.range(at: 2))
                  ) else { return nil }
            let localFullRange = match.range(at: 0)
            let localContentRange = match.range(at: 1)
            let prefixLength = localContentRange.location - localFullRange.location
            let suffixLocation = NSMaxRange(localContentRange)
            let suffixLength = NSMaxRange(localFullRange) - suffixLocation
            return InlineTextMarkSpan(
                fullRange: offset(localFullRange, by: baseLocation),
                contentRange: offset(localContentRange, by: baseLocation),
                prefixRange: NSRange(
                    location: baseLocation + localFullRange.location,
                    length: prefixLength
                ),
                suffixRange: NSRange(
                    location: baseLocation + suffixLocation,
                    length: suffixLength
                ),
                kind: kind
            )
        }
    }

    static func kind(
        in source: String,
        at selection: NSRange
    ) -> InlineTextMarkKind? {
        containingSpan(in: source, selection: selection)?.kind
    }

    static func mutation(
        in source: String,
        selection: NSRange,
        applying requestedKind: InlineTextMarkKind?
    ) -> InlineTextMarkMutation? {
        let nsSource = source as NSString
        guard selection.length > 0,
              selection.location >= 0,
              NSMaxRange(selection) <= nsSource.length else { return nil }

        let allSpans = spans(in: source)
        if let existing = containingSpan(
            in: source,
            selection: selection,
            spans: allSpans
        ) {
            let content = nsSource.substring(with: existing.contentRange)
            let nextKind = requestedKind == existing.kind ? nil : requestedKind
            let replacement = nextKind.map { encoded(content, as: $0) } ?? content
            let contentLocation = existing.fullRange.location + (nextKind == nil ? 0 : 1)
            return InlineTextMarkMutation(
                range: existing.fullRange,
                replacementText: replacement,
                selectionRange: NSRange(
                    location: contentLocation,
                    length: (content as NSString).length
                )
            )
        }

        guard requestedKind != nil,
              allSpans.allSatisfy({
                  NSIntersectionRange($0.fullRange, selection).length == 0
              }) else { return nil }

        let selectedText = nsSource.substring(with: selection)
        guard !selectedText.contains("\n"),
              !selectedText.contains("\r"),
              !selectedText.contains("["),
              !selectedText.contains("]"),
              MarkdownLinkDetector.links(in: source).allSatisfy({
                  NSIntersectionRange($0.range, selection).length == 0
              }),
              let requestedKind else { return nil }

        return InlineTextMarkMutation(
            range: selection,
            replacementText: encoded(selectedText, as: requestedKind),
            selectionRange: NSRange(
                location: selection.location + 1,
                length: selection.length
            )
        )
    }

    static func encoded(_ content: String, as kind: InlineTextMarkKind) -> String {
        "[\(content)]{.\(kind.rawValue)}"
    }

    static func removingSyntax(from source: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"\[([^\]\n]+)\]\{\.(mark|important|concept|underline)\}"#
        ) else { return source }
        return expression.stringByReplacingMatches(
            in: source,
            range: NSRange(location: 0, length: (source as NSString).length),
            withTemplate: "$1"
        )
    }

    private static func containingSpan(
        in source: String,
        selection: NSRange,
        spans: [InlineTextMarkSpan]? = nil
    ) -> InlineTextMarkSpan? {
        (spans ?? self.spans(in: source)).first { span in
            contains(span.contentRange, selection) || contains(span.fullRange, selection)
        }
    }

    private static func contains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    private static func offset(_ range: NSRange, by amount: Int) -> NSRange {
        NSRange(location: range.location + amount, length: range.length)
    }
}

private extension NSAttributedString.Key {
    static let zhijingInlineTextMark = NSAttributedString.Key(
        "com.zhijing.inline-text-mark"
    )
}

enum InlineTextMarkRenderContext {
    case screen
    case export
}

enum InlineTextMarkAttributedRenderer {
    static func renderInlineMarkdown(_ source: String) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let nsSource = source as NSString
        let spans = InlineTextMarkMarkdown.spans(in: source)
        var location = 0

        for span in spans {
            if span.fullRange.location > location {
                result.append(renderStandardMarkdown(nsSource.substring(with: NSRange(
                    location: location,
                    length: span.fullRange.location - location
                ))))
            }
            let marked = renderStandardMarkdown(
                nsSource.substring(with: span.contentRange)
            )
            if marked.length > 0 {
                marked.addAttribute(
                    .zhijingInlineTextMark,
                    value: span.kind.rawValue,
                    range: NSRange(location: 0, length: marked.length)
                )
            }
            result.append(marked)
            location = NSMaxRange(span.fullRange)
        }

        if location < nsSource.length {
            result.append(renderStandardMarkdown(nsSource.substring(from: location)))
        }
        return result
    }

    static func applyStyles(
        to attributedString: NSMutableAttributedString,
        context: InlineTextMarkRenderContext
    ) {
        let fullRange = NSRange(location: 0, length: attributedString.length)
        var markedRanges: [(InlineTextMarkKind, NSRange)] = []
        attributedString.enumerateAttribute(
            .zhijingInlineTextMark,
            in: fullRange
        ) { value, range, _ in
            guard let rawValue = value as? String,
                  let kind = InlineTextMarkKind(rawValue: rawValue) else { return }
            markedRanges.append((kind, range))
        }

        for (kind, range) in markedRanges {
            switch kind {
            case .highlight:
                attributedString.addAttribute(
                    .backgroundColor,
                    value: highlightColor(for: context),
                    range: range
                )
            case .important:
                attributedString.addAttribute(
                    .foregroundColor,
                    value: importantColor(for: context),
                    range: range
                )
                makeSemibold(attributedString, in: range)
            case .concept:
                attributedString.addAttribute(
                    .foregroundColor,
                    value: conceptColor(for: context),
                    range: range
                )
            case .underline:
                attributedString.addAttributes(
                    [
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .underlineColor: underlineColor(for: context)
                    ],
                    range: range
                )
            }
        }
        attributedString.removeAttribute(.zhijingInlineTextMark, range: fullRange)
    }

    private static func renderStandardMarkdown(
        _ source: String
    ) -> NSMutableAttributedString {
        guard !source.isEmpty else { return NSMutableAttributedString() }
        guard let attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return NSMutableAttributedString(string: source)
        }
        return NSMutableAttributedString(
            attributedString: NSAttributedString(attributed)
        )
    }

    private static func makeSemibold(
        _ attributedString: NSMutableAttributedString,
        in range: NSRange
    ) {
        attributedString.enumerateAttribute(.font, in: range) { value, subrange, _ in
            guard let font = value as? NSFont else { return }
            let traits = NSFontManager.shared.traits(of: font)
            guard !traits.contains(.boldFontMask) else { return }
            var replacement = NSFont.systemFont(
                ofSize: font.pointSize,
                weight: .semibold
            )
            if traits.contains(.italicFontMask) {
                replacement = NSFontManager.shared.convert(
                    replacement,
                    toHaveTrait: .italicFontMask
                )
            }
            attributedString.addAttribute(.font, value: replacement, range: subrange)
        }
    }

    private static func highlightColor(
        for context: InlineTextMarkRenderContext
    ) -> NSColor {
        switch context {
        case .screen: ZhijingTheme.highlightNSColor.withAlphaComponent(0.34)
        case .export: NSColor(red: 0.98, green: 0.84, blue: 0.38, alpha: 0.42)
        }
    }

    private static func importantColor(
        for context: InlineTextMarkRenderContext
    ) -> NSColor {
        switch context {
        case .screen: ZhijingTheme.importantNSColor
        case .export: NSColor(red: 0.72, green: 0.16, blue: 0.18, alpha: 1)
        }
    }

    private static func conceptColor(
        for context: InlineTextMarkRenderContext
    ) -> NSColor {
        switch context {
        case .screen: ZhijingTheme.conceptNSColor
        case .export: NSColor(red: 0.14, green: 0.38, blue: 0.68, alpha: 1)
        }
    }

    private static func underlineColor(
        for context: InlineTextMarkRenderContext
    ) -> NSColor {
        switch context {
        case .screen: ZhijingTheme.underlineNSColor
        case .export: NSColor(red: 0.31, green: 0.43, blue: 0.58, alpha: 1)
        }
    }
}
