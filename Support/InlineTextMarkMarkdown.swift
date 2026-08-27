import AppKit
import Foundation

enum InlineTextMarkKind: String, CaseIterable, Sendable {
    case highlight = "mark"
    case important
    case concept
    case underline
    case red
    case orange
    case green
    case blue

    var title: String {
        switch self {
        case .highlight: "荧光标记"
        case .important: "重要 / 警示"
        case .concept: "概念 / 线索"
        case .underline: "下划线"
        case .red: "红色文字"
        case .orange: "橙色文字"
        case .green: "绿色文字"
        case .blue: "蓝色文字"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .highlight: "黄色荧光背景"
        case .important: "红色重点文字"
        case .concept: "蓝色概念文字"
        case .underline: "保留原色并添加下划线"
        case .red: "红色文字"
        case .orange: "橙色文字"
        case .green: "绿色文字"
        case .blue: "蓝色文字"
        }
    }

    /// 标记语法里的种类列表，例如 "mark|important|…"。
    /// 注意顺序：没有前缀冲突的固定词表，直接拼接安全。
    static var syntaxAlternation: String {
        allCases.map(\.rawValue).joined(separator: "|")
    }

    /// 划词悬浮条空间有限，只放最常用的标记；颜色文字走格式栏与右键菜单。
    var showsInSelectionPills: Bool {
        switch self {
        case .highlight, .important, .concept, .underline: true
        case .red, .orange, .green, .blue: false
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

private struct EncodedInlineTextMarkSelection {
    let text: String
    let contentRanges: [NSRange]
}

enum InlineTextMarkMarkdown {
    static func spans(
        in source: String,
        baseLocation: Int = 0
    ) -> [InlineTextMarkSpan] {
        guard let expression = try? NSRegularExpression(
            pattern: #"\[([^\]\n]+)\]\{\.("# + InlineTextMarkKind.syntaxAlternation + #")\}"#
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

    static func containsMark(
        in source: String,
        intersecting selection: NSRange
    ) -> Bool {
        spans(in: source).contains {
            NSIntersectionRange($0.fullRange, selection).length > 0
        }
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

        let intersectingSpans = allSpans.filter {
            NSIntersectionRange($0.fullRange, selection).length > 0
        }
        if requestedKind == nil {
            return removingMarks(
                from: nsSource,
                selection: selection,
                intersectingSpans: intersectingSpans
            )
        }

        guard intersectingSpans.allSatisfy({
            contains(selection, $0.fullRange)
        }) else { return nil }

        let selectedText = nsSource.substring(with: selection)
        guard MarkdownLinkDetector.links(in: source).allSatisfy({
                  NSIntersectionRange($0.range, selection).length == 0
              }),
              !intersectsCodeFence(
                  in: source,
                  selection: selection,
                  selectedText: selectedText
              ),
              let requestedKind else { return nil }

        let plainSelection = removingSyntax(from: selectedText)
        guard let encodedSelection = encodedSelection(
            plainSelection,
            source: nsSource,
            sourceLocation: selection.location,
            as: requestedKind
        ) else { return nil }

        let replacementLength = (encodedSelection.text as NSString).length
        let nextSelection: NSRange
        if encodedSelection.contentRanges.count == 1,
           let contentRange = encodedSelection.contentRanges.first {
            nextSelection = NSRange(
                location: selection.location + contentRange.location,
                length: contentRange.length
            )
        } else {
            nextSelection = NSRange(
                location: selection.location,
                length: replacementLength
            )
        }

        return InlineTextMarkMutation(
            range: selection,
            replacementText: encodedSelection.text,
            selectionRange: nextSelection
        )
    }

    static func encoded(_ content: String, as kind: InlineTextMarkKind) -> String {
        "[\(content)]{.\(kind.rawValue)}"
    }

    static func removingSyntax(from source: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"\[([^\]\n]+)\]\{\.("# + InlineTextMarkKind.syntaxAlternation + #")\}"#
        ) else { return source }
        return expression.stringByReplacingMatches(
            in: source,
            range: NSRange(location: 0, length: (source as NSString).length),
            withTemplate: "$1"
        )
    }

    private static func removingMarks(
        from source: NSString,
        selection: NSRange,
        intersectingSpans: [InlineTextMarkSpan]
    ) -> InlineTextMarkMutation? {
        guard !intersectingSpans.isEmpty,
              intersectingSpans.allSatisfy({
                  contains(selection, $0.fullRange)
              }),
              let first = intersectingSpans.first,
              let last = intersectingSpans.last else { return nil }

        let mutationRange = NSRange(
            location: first.fullRange.location,
            length: NSMaxRange(last.fullRange) - first.fullRange.location
        )
        let replacement = removingSyntax(
            from: source.substring(with: mutationRange)
        )
        let removedLength = intersectingSpans.reduce(0) { partial, span in
            partial + span.fullRange.length - span.contentRange.length
        }
        return InlineTextMarkMutation(
            range: mutationRange,
            replacementText: replacement,
            selectionRange: NSRange(
                location: selection.location,
                length: selection.length - removedLength
            )
        )
    }

    private static func encodedSelection(
        _ selection: String,
        source: NSString,
        sourceLocation: Int,
        as kind: InlineTextMarkKind
    ) -> EncodedInlineTextMarkSelection? {
        guard let lineBreakExpression = try? NSRegularExpression(
            pattern: #"\r\n|\n|\r"#
        ) else { return nil }

        let nsSelection = selection as NSString
        let lineBreaks = lineBreakExpression.matches(
            in: selection,
            range: NSRange(location: 0, length: nsSelection.length)
        )
        var cursor = 0
        var replacement = ""
        var contentRanges: [NSRange] = []
        var isFirstLine = true

        for lineBreak in lineBreaks {
            appendEncodedLine(
                nsSelection.substring(with: NSRange(
                    location: cursor,
                    length: lineBreak.range.location - cursor
                )),
                preservesBlockPrefix: !isFirstLine || isLineStart(
                    sourceLocation,
                    in: source
                ),
                kind: kind,
                replacement: &replacement,
                contentRanges: &contentRanges
            )
            replacement += nsSelection.substring(with: lineBreak.range)
            cursor = NSMaxRange(lineBreak.range)
            isFirstLine = false
        }

        appendEncodedLine(
            nsSelection.substring(from: cursor),
            preservesBlockPrefix: !isFirstLine || isLineStart(
                sourceLocation,
                in: source
            ),
            kind: kind,
            replacement: &replacement,
            contentRanges: &contentRanges
        )

        guard !contentRanges.isEmpty else { return nil }
        return EncodedInlineTextMarkSelection(
            text: replacement,
            contentRanges: contentRanges
        )
    }

    private static func appendEncodedLine(
        _ line: String,
        preservesBlockPrefix: Bool,
        kind: InlineTextMarkKind,
        replacement: inout String,
        contentRanges: inout [NSRange]
    ) {
        let nsLine = line as NSString
        guard let contentRange = markableContentRange(
            in: nsLine,
            preservesBlockPrefix: preservesBlockPrefix
        ) else {
            replacement += line
            return
        }

        let content = nsLine.substring(with: contentRange)
        guard !content.contains("["), !content.contains("]") else {
            replacement += line
            return
        }

        let replacementStart = (replacement as NSString).length
        replacement += nsLine.substring(to: contentRange.location)
        replacement += encoded(content, as: kind)
        replacement += nsLine.substring(from: NSMaxRange(contentRange))
        contentRanges.append(NSRange(
            location: replacementStart + contentRange.location + 1,
            length: contentRange.length
        ))
    }

    private static func markableContentRange(
        in line: NSString,
        preservesBlockPrefix: Bool
    ) -> NSRange? {
        var lowerBound = 0
        var upperBound = line.length
        while lowerBound < upperBound,
              isHorizontalWhitespace(line.character(at: lowerBound)) {
            lowerBound += 1
        }
        while upperBound > lowerBound,
              isHorizontalWhitespace(line.character(at: upperBound - 1)) {
            upperBound -= 1
        }
        guard lowerBound < upperBound else { return nil }

        if preservesBlockPrefix {
            let indentationLength = lowerBound
            if indentationLength >= 4 { return nil }
            let candidateRange = NSRange(
                location: lowerBound,
                length: upperBound - lowerBound
            )
            let candidate = line.substring(with: candidateRange)
            if candidate.hasPrefix("```") || candidate.hasPrefix("~~~") {
                return nil
            }
            if isThematicBreak(candidate) { return nil }
            if let expression = try? NSRegularExpression(
                pattern: #"^(?:#{1,6}[ \t]+|>[ \t]?|[-+*][ \t]+\[[ xX]\][ \t]+|(?:[-+*]|[0-9]+[.)])[ \t]+)"#
            ), let match = expression.firstMatch(
                in: candidate,
                range: NSRange(location: 0, length: (candidate as NSString).length)
            ) {
                lowerBound += match.range.length
            }
        }

        while lowerBound < upperBound,
              isHorizontalWhitespace(line.character(at: lowerBound)) {
            lowerBound += 1
        }
        guard lowerBound < upperBound else { return nil }
        return NSRange(
            location: lowerBound,
            length: upperBound - lowerBound
        )
    }

    private static func isLineStart(
        _ location: Int,
        in source: NSString
    ) -> Bool {
        guard location > 0 else { return true }
        let previous = source.character(at: location - 1)
        return previous == 10 || previous == 13
    }

    private static func isHorizontalWhitespace(_ character: unichar) -> Bool {
        character == 9 || character == 32
    }

    private static func isThematicBreak(_ candidate: String) -> Bool {
        let compact = candidate.filter { $0 != " " && $0 != "\t" }
        guard compact.count >= 3, let marker = compact.first,
              marker == "-" || marker == "*" || marker == "_" else {
            return false
        }
        return compact.allSatisfy { $0 == marker }
    }

    private static func intersectsCodeFence(
        in source: String,
        selection: NSRange,
        selectedText: String
    ) -> Bool {
        if MarkdownFenceStateResolver.isInsideFence(
            before: selection.location,
            in: source
        ) {
            return true
        }
        return selectedText.components(separatedBy: .newlines).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
        }
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
            case .red:
                attributedString.addAttribute(
                    .foregroundColor,
                    value: kindColor(.red, for: context),
                    range: range
                )
            case .orange:
                attributedString.addAttribute(
                    .foregroundColor,
                    value: kindColor(.orange, for: context),
                    range: range
                )
            case .green:
                attributedString.addAttribute(
                    .foregroundColor,
                    value: kindColor(.green, for: context),
                    range: range
                )
            case .blue:
                attributedString.addAttribute(
                    .foregroundColor,
                    value: kindColor(.blue, for: context),
                    range: range
                )
            }
        }
        attributedString.removeAttribute(.zhijingInlineTextMark, range: fullRange)
    }

    private static let strikethroughExpression = try? NSRegularExpression(
        pattern: #"~~[^~\n]+~~"#
    )

    private static func renderStandardMarkdown(
        _ source: String
    ) -> NSMutableAttributedString {
        guard !source.isEmpty else { return NSMutableAttributedString() }
        // SwiftUI 的 AttributedString(markdown:) 不解析 ~~删除线~~，这里手动分段处理。
        let nsSource = source as NSString
        let matches = strikethroughExpression?.matches(
            in: source,
            range: NSRange(location: 0, length: nsSource.length)
        ) ?? []
        guard !matches.isEmpty else {
            return inlineOnlyAttributed(source)
        }

        let result = NSMutableAttributedString()
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                result.append(inlineOnlyAttributed(nsSource.substring(
                    with: NSRange(location: cursor, length: match.range.location - cursor)
                )))
            }
            let inner = nsSource.substring(with: match.range)
                .dropFirst(2).dropLast(2)
            let rendered = inlineOnlyAttributed(String(inner))
            rendered.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: NSRange(location: 0, length: rendered.length)
            )
            result.append(rendered)
            cursor = NSMaxRange(match.range)
        }
        if cursor < nsSource.length {
            result.append(inlineOnlyAttributed(nsSource.substring(from: cursor)))
        }
        return result
    }

    private static func inlineOnlyAttributed(
        _ source: String
    ) -> NSMutableAttributedString {
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

    private static func kindColor(
        _ kind: InlineTextMarkKind,
        for context: InlineTextMarkRenderContext
    ) -> NSColor {
        switch context {
        case .screen:
            switch kind {
            case .red: NSColor.systemRed
            case .orange: NSColor.systemOrange
            case .green: NSColor.systemGreen
            case .blue: NSColor.systemBlue
            default: ZhijingTheme.accentNSColor
            }
        case .export:
            switch kind {
            case .red: NSColor(red: 0.80, green: 0.16, blue: 0.12, alpha: 1)
            case .orange: NSColor(red: 0.82, green: 0.45, blue: 0.05, alpha: 1)
            case .green: NSColor(red: 0.13, green: 0.55, blue: 0.24, alpha: 1)
            case .blue: NSColor(red: 0.10, green: 0.38, blue: 0.72, alpha: 1)
            default: NSColor.black
            }
        }
    }
}
