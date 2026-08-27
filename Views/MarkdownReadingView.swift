import AppKit
import SwiftUI

struct MarkdownReadingView: View {
    let text: String
    var onSelectionChange: (String?) -> Void = { _ in }

    var body: some View {
        MarkdownSelectableReadingView(
            text: text,
            onSelectionChange: onSelectionChange
        )
    }
}

private struct MarkdownSelectableReadingView: NSViewRepresentable {
    let text: String
    let onSelectionChange: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectionChange: onSelectionChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = ZhijingTheme.paperNSColor
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = MarkdownReadingTextView(
            frame: scrollView.contentView.bounds
        )
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(
            width: 0,
            height: scrollView.contentSize.height
        )
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.delegate = context.coordinator
        scrollView.documentView = textView
        context.coordinator.render(text, into: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownReadingTextView
        else { return }
        context.coordinator.render(text, into: textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var source: String?
        private var renderTask: Task<Void, Never>?
        private let onSelectionChange: (String?) -> Void

        init(onSelectionChange: @escaping (String?) -> Void) {
            self.onSelectionChange = onSelectionChange
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            guard range.length > 0,
                  NSMaxRange(range) <= (textView.string as NSString).length else {
                onSelectionChange(nil)
                return
            }
            onSelectionChange(
                (textView.string as NSString).substring(with: range)
            )
        }

        func render(_ text: String, into textView: MarkdownReadingTextView) {
            guard source != text else { return }
            source = text
            renderTask?.cancel()

            let selection = textView.selectedRange()
            let visibleOrigin = textView.enclosingScrollView?.contentView.bounds.origin
            renderTask = Task { [weak textView] in
                let rendered = await Task.detached(priority: .userInitiated) {
                    SendableAttributedString(
                        MarkdownReadingRenderCache.shared.render(text)
                    )
                }.value
                guard !Task.isCancelled, source == text, let textView else { return }
                textView.textStorage?.setAttributedString(rendered.value)

                let length = textView.textStorage?.length ?? 0
                let location = min(selection.location, length)
                textView.setSelectedRange(NSRange(
                    location: location,
                    length: min(selection.length, length - location)
                ))
                if let scrollView = textView.enclosingScrollView, let visibleOrigin {
                    scrollView.contentView.scroll(to: visibleOrigin)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
        }
    }
}

private struct SendableAttributedString: @unchecked Sendable {
    let value: NSAttributedString

    init(_ value: NSAttributedString) {
        self.value = value
    }
}

final class MarkdownReadingTextView: NSTextView {
    private let maximumContentWidth: CGFloat = 820
    private let minimumHorizontalInset: CGFloat = 46

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let centeredInset = (newSize.width - maximumContentWidth) / 2
        textContainerInset = NSSize(
            width: max(minimumHorizontalInset, centeredInset),
            height: 38
        )
    }
}

private final class MarkdownReadingRenderCache: @unchecked Sendable {
    static let shared = MarkdownReadingRenderCache()

    private var values: [String: (source: String, rendered: NSAttributedString)] = [:]
    private var order: [String] = []
    private let limit = 10
    private let lock = NSLock()

    func render(_ markdown: String) -> NSAttributedString {
        let key = "\(markdown.utf16.count)-\(markdown.hashValue)"
        lock.lock()
        if let cached = values[key], cached.source == markdown {
            lock.unlock()
            return cached.rendered
        }
        lock.unlock()

        let rendered = MarkdownReadingAttributedRenderer.render(markdown)
        lock.lock()
        values[key] = (markdown, rendered)
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit {
            let removed = order.removeFirst()
            values[removed] = nil
        }
        lock.unlock()
        return rendered
    }
}

enum MarkdownReadingAttributedRenderer {
    static func render(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for block in MarkdownReadingParser.parse(markdown) {
            switch block.kind {
            case .heading(let level):
                let size: CGFloat = switch level {
                case 1: 29
                case 2: 23
                case 3: 19
                default: 17
                }
                append(
                    block.content,
                    to: result,
                    font: .systemFont(
                        ofSize: size,
                        weight: level <= 2 ? .bold : .semibold
                    ),
                    color: ZhijingTheme.accentNSColor,
                    spacingBefore: level == 1 ? 4 : 14,
                    spacingAfter: level == 1 ? 18 : 9
                )
            case .paragraph:
                append(
                    block.content,
                    to: result,
                    font: .systemFont(ofSize: 16),
                    lineSpacing: 6,
                    spacingAfter: 14
                )
            case .quote:
                append(
                    "│  \(block.content)",
                    to: result,
                    font: .systemFont(ofSize: 16).italic,
                    color: ZhijingTheme.quoteNSColor,
                    backgroundColor: ZhijingTheme.quoteNSColor.withAlphaComponent(0.05),
                    leftIndent: 14,
                    spacingBefore: 10,
                    spacingAfter: 14
                )
            case .annotation:
                appendAnnotation(block.content, to: result)
            case .unorderedList(let indentation):
                append(
                    "•  \(block.content)",
                    to: result,
                    font: .systemFont(ofSize: 16),
                    leftIndent: CGFloat(indentation) * 18 + 20,
                    firstLineIndent: CGFloat(indentation) * 18,
                    lineSpacing: 5,
                    spacingAfter: 7
                )
            case .orderedList(let marker, let indentation):
                append(
                    "\(marker)  \(block.content)",
                    to: result,
                    font: .systemFont(ofSize: 16),
                    leftIndent: CGFloat(indentation) * 18 + 28,
                    firstLineIndent: CGFloat(indentation) * 18,
                    lineSpacing: 5,
                    spacingAfter: 7
                )
            case .code:
                append(
                    block.content,
                    to: result,
                    font: .monospacedSystemFont(ofSize: 14, weight: .regular),
                    color: ZhijingTheme.codeNSColor,
                    backgroundColor: .secondaryLabelColor.withAlphaComponent(0.08),
                    leftIndent: 14,
                    lineSpacing: 3,
                    spacingBefore: 6,
                    spacingAfter: 12
                )
            case .divider:
                append(
                    "────────────────────────────────────────",
                    to: result,
                    font: .systemFont(ofSize: 10),
                    color: ZhijingTheme.accentNSColor.withAlphaComponent(0.28),
                    spacingBefore: 20,
                    spacingAfter: 20
                )
            case .space:
                result.append(NSAttributedString(string: "\n"))
            }
        }
        return result
    }

    private static func appendAnnotation(
        _ source: String,
        to result: NSMutableAttributedString
    ) {
        var lines = source.components(separatedBy: .newlines)
        let context = lines.first ?? ""
        if !lines.isEmpty { lines.removeFirst() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        let body = lines.joined(separator: "\n")
        let background = ZhijingTheme.annotationNSColor.withAlphaComponent(0.045)

        append(
            "●  批注",
            to: result,
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: ZhijingTheme.annotationNSColor,
            backgroundColor: background,
            leftIndent: 16,
            spacingBefore: 10,
            spacingAfter: 4
        )
        if !context.isEmpty {
            append(
                context,
                to: result,
                font: .systemFont(ofSize: 13),
                color: .secondaryLabelColor,
                backgroundColor: background,
                leftIndent: 30,
                lineSpacing: 3,
                spacingAfter: 7
            )
        }
        append(
            body,
            to: result,
            font: .systemFont(ofSize: 15.5),
            color: .labelColor,
            backgroundColor: background,
            leftIndent: 30,
            lineSpacing: 5,
            spacingAfter: 16
        )
    }

    private static func append(
        _ source: String,
        to result: NSMutableAttributedString,
        font: NSFont,
        color: NSColor = .labelColor,
        backgroundColor: NSColor? = nil,
        leftIndent: CGFloat = 0,
        firstLineIndent: CGFloat? = nil,
        lineSpacing: CGFloat = 0,
        spacingBefore: CGFloat = 0,
        spacingAfter: CGFloat
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacingBefore = spacingBefore
        paragraph.paragraphSpacing = spacingAfter
        paragraph.headIndent = leftIndent
        paragraph.firstLineHeadIndent = firstLineIndent ?? leftIndent

        let rendered = inlineMarkdown(source.isEmpty ? " " : source)
        let range = NSRange(location: 0, length: rendered.length)
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        if let backgroundColor {
            attributes[.backgroundColor] = backgroundColor
        }
        rendered.addAttributes(attributes, range: range)
        rendered.enumerateAttribute(.font, in: range) { value, subrange, _ in
            if let existing = value as? NSFont {
                rendered.addAttribute(
                    .font,
                    value: NSFontManager.shared.convert(
                        existing,
                        toSize: font.pointSize
                    ),
                    range: subrange
                )
            } else {
                rendered.addAttribute(.font, value: font, range: subrange)
            }
        }
        if rendered.length > 0,
           rendered.attribute(.font, at: 0, effectiveRange: nil) == nil {
            rendered.addAttribute(.font, value: font, range: range)
        }
        rendered.enumerateAttribute(.link, in: range) { value, subrange, _ in
            if value != nil {
                rendered.addAttribute(
                    .foregroundColor,
                    value: NSColor.linkColor,
                    range: subrange
                )
            }
        }
        InlineTextMarkAttributedRenderer.applyStyles(
            to: rendered,
            context: .screen
        )
        rendered.append(NSAttributedString(string: "\n"))
        result.append(rendered)
    }

    private static func inlineMarkdown(
        _ source: String
    ) -> NSMutableAttributedString {
        InlineTextMarkAttributedRenderer.renderInlineMarkdown(source)
    }
}

struct MarkdownReadingBlock: Identifiable {
    enum Kind {
        case heading(level: Int)
        case paragraph
        case quote
        case annotation
        case unorderedList(indentation: Int)
        case orderedList(marker: String, indentation: Int)
        case code
        case divider
        case space
    }

    let id: Int
    let kind: Kind
    let content: String
}

enum MarkdownReadingParser {
    static func parse(_ source: String) -> [MarkdownReadingBlock] {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [MarkdownReadingBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var annotationLines: [String] = []
        var isInsideCodeFence = false
        var isInsideAnnotation = false

        func append(_ kind: MarkdownReadingBlock.Kind, _ content: String = "") {
            blocks.append(.init(id: blocks.count, kind: kind, content: content))
        }

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            append(.paragraph, paragraphLines.joined(separator: "\n"))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        func flushAnnotation() {
            guard isInsideAnnotation else { return }
            while annotationLines.last?.isEmpty == true {
                annotationLines.removeLast()
            }
            append(.annotation, annotationLines.joined(separator: "\n"))
            annotationLines.removeAll(keepingCapacity: true)
            isInsideAnnotation = false
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if isInsideAnnotation {
                if trimmed.hasPrefix(">") {
                    annotationLines.append(
                        String(trimmed.dropFirst())
                            .trimmingCharacters(in: .whitespaces)
                    )
                    continue
                }
                flushAnnotation()
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                if isInsideCodeFence {
                    append(.code, codeLines.joined(separator: "\n"))
                    codeLines.removeAll(keepingCapacity: true)
                }
                isInsideCodeFence.toggle()
                continue
            }

            if isInsideCodeFence {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                if blocks.last.map({ !isSpace($0.kind) }) ?? false {
                    append(.space)
                }
                continue
            }

            if let heading = heading(in: trimmed) {
                flushParagraph()
                append(.heading(level: heading.level), heading.content)
            } else if isDivider(trimmed) {
                flushParagraph()
                append(.divider)
            } else if InlineAnnotationMarkdown.isHeading(trimmed) {
                flushParagraph()
                isInsideAnnotation = true
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                let content = String(trimmed.dropFirst())
                    .trimmingCharacters(in: .whitespaces)
                append(.quote, content)
            } else if let item = unorderedItem(in: line) {
                flushParagraph()
                append(.unorderedList(indentation: item.indentation), item.content)
            } else if let item = orderedItem(in: line) {
                flushParagraph()
                append(
                    .orderedList(
                        marker: item.marker,
                        indentation: item.indentation
                    ),
                    item.content
                )
            } else {
                paragraphLines.append(line)
            }
        }

        flushParagraph()
        flushAnnotation()
        if isInsideCodeFence && !codeLines.isEmpty {
            append(.code, codeLines.joined(separator: "\n"))
        }
        while blocks.last.map({ isSpace($0.kind) }) ?? false {
            blocks.removeLast()
        }
        return blocks
    }

    private static func heading(in line: String) -> (level: Int, content: String)? {
        let hashes = line.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count),
              line.dropFirst(hashes.count).first?.isWhitespace == true else {
            return nil
        }
        return (
            hashes.count,
            String(line.dropFirst(hashes.count))
                .trimmingCharacters(in: .whitespaces)
        )
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first else { return false }
        return (first == "-" || first == "*" || first == "_")
            && compact.allSatisfy { $0 == first }
    }

    private static func unorderedItem(
        in line: String
    ) -> (indentation: Int, content: String)? {
        let indentation = line.prefix(while: { $0 == " " }).count / 2
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first,
              "-+*".contains(marker),
              trimmed.dropFirst().first?.isWhitespace == true else { return nil }
        return (
            indentation,
            String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        )
    }

    private static func orderedItem(
        in line: String
    ) -> (marker: String, indentation: Int, content: String)? {
        let indentation = line.prefix(while: { $0 == " " }).count / 2
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        let remainder = trimmed.dropFirst(digits.count)
        guard let punctuation = remainder.first,
              punctuation == "." || punctuation == ")",
              remainder.dropFirst().first?.isWhitespace == true else { return nil }
        return (
            "\(digits)\(punctuation)",
            indentation,
            String(remainder.dropFirst()).trimmingCharacters(in: .whitespaces)
        )
    }

    private static func isSpace(_ kind: MarkdownReadingBlock.Kind) -> Bool {
        if case .space = kind { return true }
        return false
    }
}

private extension NSFont {
    var italic: NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask)
    }
}
