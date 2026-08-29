import AppKit
import SwiftUI

struct MarkdownReadingView: View {
    let text: String
    var baseURL: URL?
    var onSelectionChange: (String?) -> Void = { _ in }
    var onToggleTaskLine: (Int) -> Void = { _ in }

    var body: some View {
        MarkdownSelectableReadingView(
            text: text,
            baseURL: baseURL,
            onSelectionChange: onSelectionChange,
            onToggleTaskLine: onToggleTaskLine
        )
    }
}

private struct MarkdownSelectableReadingView: NSViewRepresentable {
    let text: String
    let baseURL: URL?
    let onSelectionChange: (String?) -> Void
    let onToggleTaskLine: (Int) -> Void

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
        textView.onToggleTaskLine = onToggleTaskLine
        context.coordinator.render(text, baseURL: baseURL, into: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownReadingTextView
        else { return }
        textView.onToggleTaskLine = onToggleTaskLine
        context.coordinator.render(text, baseURL: baseURL, into: textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var source: String?
        private var renderedBaseURL: URL?
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

        func render(
            _ text: String,
            baseURL: URL?,
            into textView: MarkdownReadingTextView
        ) {
            guard source != text || renderedBaseURL != baseURL else { return }
            source = text
            renderedBaseURL = baseURL
            renderTask?.cancel()

            let selection = textView.selectedRange()
            let visibleOrigin = textView.enclosingScrollView?.contentView.bounds.origin
            renderTask = Task { [weak textView] in
                let rendered = await Task.detached(priority: .userInitiated) {
                    SendableAttributedString(
                        MarkdownReadingRenderCache.shared.render(
                            text,
                            baseURL: baseURL
                        )
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
    var onToggleTaskLine: ((Int) -> Void)?

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

    override func mouseDown(with event: NSEvent) {
        if let line = taskLine(at: event.locationInWindow) {
            onToggleTaskLine?(line)
            return
        }
        super.mouseDown(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        if taskLine(at: event.locationInWindow) != nil {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    private func taskLine(at pointInWindow: NSPoint) -> Int? {
        let point = convert(pointInWindow, from: nil)
        guard let layoutManager, let textContainer else { return nil }
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(
            for: point,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        let length = (string as NSString).length
        guard index < length else { return nil }
        return textStorage?.attribute(
            .zhijingTaskCheckbox,
            at: index,
            effectiveRange: nil
        ) as? Int
    }
}

private extension NSAttributedString.Key {
    static let zhijingTaskCheckbox = NSAttributedString.Key(
        "com.zhijing.reading-task-checkbox"
    )
}

private final class MarkdownReadingRenderCache: @unchecked Sendable {
    static let shared = MarkdownReadingRenderCache()

    private var values: [String: (source: String, rendered: NSAttributedString)] = [:]
    private var order: [String] = []
    private let limit = 10
    private let lock = NSLock()

    func render(
        _ markdown: String,
        baseURL: URL? = nil
    ) -> NSAttributedString {
        let key = "\(baseURL?.standardizedFileURL.path ?? "")|"
            + "\(markdown.utf16.count)-\(markdown.hashValue)"
        lock.lock()
        if let cached = values[key], cached.source == markdown {
            lock.unlock()
            return cached.rendered
        }
        lock.unlock()

        let rendered = MarkdownReadingAttributedRenderer.render(
            markdown,
            baseURL: baseURL
        )
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
    static func render(
        _ markdown: String,
        baseURL: URL? = nil
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var annotationNumber = 0
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
                annotationNumber += 1
                appendAnnotation(
                    block.content,
                    number: annotationNumber,
                    to: result
                )
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
            case .taskList(let indentation, let isChecked):
                appendTaskList(
                    block,
                    indentation: indentation,
                    isChecked: isChecked,
                    to: result
                )
            case .image:
                if !appendImage(
                    block.content,
                    baseURL: baseURL,
                    to: result
                ) {
                    append(
                        block.content,
                        to: result,
                        font: .systemFont(ofSize: 16),
                        lineSpacing: 6,
                        spacingAfter: 14
                    )
                }
            case .table(let header, let rows):
                appendTable(header: header, rows: rows, to: result)
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
        number: Int,
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
        append(
            " " + InlineAnnotationMarkdown.circledNumber(number),
            to: result,
            font: .systemFont(ofSize: 12, weight: .semibold),
            color: ZhijingTheme.annotationWaveNSColor,
            backgroundColor: background,
            spacingAfter: 4
        )
        if !context.isEmpty {
            append(
                InlineAnnotationMarkdown.shortenedExcerpt(from: context),
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

    private static func appendTaskList(
        _ block: MarkdownReadingBlock,
        indentation: Int,
        isChecked: Bool,
        to result: NSMutableAttributedString
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        paragraph.paragraphSpacing = 7
        paragraph.headIndent = CGFloat(indentation) * 18 + 20
        paragraph.firstLineHeadIndent = CGFloat(indentation) * 18

        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(
            string: isChecked ? "☑  " : "☐  ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 16),
                .foregroundColor: isChecked
                    ? ZhijingTheme.accentNSColor
                    : NSColor.secondaryLabelColor,
                .zhijingTaskCheckbox: block.sourceLine
            ]
        ))
        attributed.append(inlineMarkdown(block.content))
        let range = NSRange(location: 0, length: attributed.length)
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: range)
        attributed.enumerateAttribute(.font, in: range) { value, subrange, _ in
            if let existing = value as? NSFont {
                attributed.addAttribute(
                    .font,
                    value: NSFontManager.shared.convert(
                        existing,
                        toSize: 16
                    ),
                    range: subrange
                )
            } else {
                attributed.addAttribute(
                    .font,
                    value: NSFont.systemFont(ofSize: 16),
                    range: subrange
                )
            }
        }
        InlineTextMarkAttributedRenderer.applyStyles(
            to: attributed,
            context: .screen
        )
        attributed.append(NSAttributedString(string: "\n"))
        result.append(attributed)
    }

    /// 返回是否成功渲染为图片；失败时调用方回退为普通段落。
    private static func appendImage(
        _ markdown: String,
        baseURL: URL?,
        to result: NSMutableAttributedString
    ) -> Bool {
        guard let (alt, path) = imageURL(in: markdown),
              let image = loadImage(at: path, baseURL: baseURL) else {
            return false
        }

        let attachment = NSTextAttachment()
        attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
        let maximumImageWidth: CGFloat = 760
        let maximumImageHeight: CGFloat = 560
        var size = image.size
        let scale = min(
            maximumImageWidth / max(size.width, 1),
            maximumImageHeight / max(size.height, 1),
            1
        )
        size = NSSize(
            width: size.width * scale,
            height: size.height * scale
        )
        attachment.bounds = NSRect(
            origin: .zero,
            size: size
        )

        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = 8
        paragraph.paragraphSpacing = 14

        let attributed = NSMutableAttributedString(attachment: attachment)
        if !alt.isEmpty {
            attributed.append(NSAttributedString(
                string: "  \(alt)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            ))
        }
        let range = NSRange(location: 0, length: attributed.length)
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: range)
        attributed.append(NSAttributedString(string: "\n"))
        result.append(attributed)
        return true
    }

    private static func imageURL(
        in markdown: String
    ) -> (alt: String, path: String)? {
        guard markdown.hasPrefix("![") else { return nil }
        guard let altEnd = markdown.range(of: "]") else { return nil }
        let alt = String(markdown[markdown.index(after: markdown.startIndex)..<altEnd.lowerBound])
        let remainder = markdown[altEnd.upperBound...]
        guard remainder.hasPrefix("("), remainder.hasSuffix(")") else { return nil }
        let path = String(remainder.dropFirst().dropLast())
            .trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        return (alt.trimmingCharacters(in: .whitespaces), path)
    }

    private static func loadImage(
        at path: String,
        baseURL: URL?
    ) -> NSImage? {
        let url: URL
        if path.lowercased().hasPrefix("http://") || path.lowercased().hasPrefix("https://") {
            // 阅读渲染在后台线程同步执行，不做网络请求，远程图片回退为文字。
            return nil
        } else if path.hasPrefix("/") {
            url = URL(filePath: path)
        } else if let baseURL {
            url = baseURL.appending(path: path)
        } else {
            url = URL(filePath: path)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    private static func appendTable(
        header: [String],
        rows: [[String]],
        to result: NSMutableAttributedString
    ) {
        let font = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return }

        let padding: CGFloat = 16
        var columnWidths = Array(repeating: CGFloat(0), count: columnCount)
        for row in [header] + rows {
            for (index, cell) in row.enumerated() where index < columnCount {
                columnWidths[index] = max(
                    columnWidths[index],
                    textWidth(cell, font: font)
                )
            }
        }
        let paddedWidths = columnWidths.map { $0 + padding }

        func appendRow(_ row: [String], isHeader: Bool) {
            let lineFont = isHeader
                ? NSFont.monospacedSystemFont(ofSize: 13.5, weight: .semibold)
                : font
            let line = NSMutableAttributedString()
            for index in 0..<columnCount {
                let cell = index < row.count ? row[index] : ""
                let lineText = NSMutableAttributedString(
                    string: cell,
                    attributes: [
                        .font: lineFont,
                        .foregroundColor: NSColor.labelColor
                    ]
                )
                lineText.append(NSAttributedString(
                    string: String(
                        repeating: " ",
                        count: padCount(
                            textWidth(cell, font: lineFont),
                            target: paddedWidths[index],
                            spaceFont: font
                        )
                    )
                ))
                line.append(lineText)
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            line.addAttribute(
                .paragraphStyle,
                value: paragraph,
                range: NSRange(location: 0, length: line.length)
            )
            line.append(NSAttributedString(string: "\n"))
            result.append(line)
        }

        let totalWidth = paddedWidths.reduce(0, +)
        let separator = NSMutableAttributedString()
        let dashWidth = textWidth("─", font: font)
        separator.append(NSAttributedString(
            string: String(repeating: "─", count: max(4, Int(totalWidth / max(dashWidth, 1)))),
            attributes: [
                .font: font,
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
        ))
        let separatorParagraph = NSMutableParagraphStyle()
        separatorParagraph.lineSpacing = 2
        separator.addAttribute(
            .paragraphStyle,
            value: separatorParagraph,
            range: NSRange(location: 0, length: separator.length)
        )
        separator.append(NSAttributedString(string: "\n"))

        appendRow(header, isHeader: true)
        result.append(separator)
        for row in rows {
            appendRow(row, isHeader: false)
        }
        result.append(NSAttributedString(string: "\n"))
    }

    private static func textWidth(
        _ text: String,
        font: NSFont
    ) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font])
            .size().width
    }

    private static func padCount(
        _ current: CGFloat,
        target: CGFloat,
        spaceFont: NSFont
    ) -> Int {
        let spaceWidth = max(textWidth(" ", font: spaceFont), 1)
        guard target > current else { return 0 }
        return Int(ceil((target - current) / spaceWidth))
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
        case taskList(indentation: Int, isChecked: Bool)
        case image
        case table(header: [String], rows: [[String]])
        case code
        case divider
        case space
    }

    let id: Int
    let kind: Kind
    let content: String
    /// 在源文件中的行号（从 1 开始），用于任务列表点击写回。
    let sourceLine: Int
}

enum MarkdownReadingParser {
    static func parse(_ source: String) -> [MarkdownReadingBlock] {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [MarkdownReadingBlock] = []
        var paragraphLines: [String] = []
        var paragraphLineNumbers: [Int] = []
        var codeLines: [String] = []
        var annotationLines: [String] = []
        var isInsideCodeFence = false
        var isInsideAnnotation = false
        var index = 0

        func append(
            _ kind: MarkdownReadingBlock.Kind,
            _ content: String = "",
            _ sourceLine: Int
        ) {
            blocks.append(.init(
                id: blocks.count,
                kind: kind,
                content: content,
                sourceLine: sourceLine
            ))
        }

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            append(
                .paragraph,
                paragraphLines.joined(separator: "\n"),
                paragraphLineNumbers.first ?? 1
            )
            paragraphLines.removeAll(keepingCapacity: true)
            paragraphLineNumbers.removeAll(keepingCapacity: true)
        }

        func flushAnnotation() {
            guard isInsideAnnotation else { return }
            while annotationLines.last?.isEmpty == true {
                annotationLines.removeLast()
            }
            append(.annotation, annotationLines.joined(separator: "\n"), 1)
            annotationLines.removeAll(keepingCapacity: true)
            isInsideAnnotation = false
        }

        while index < lines.count {
            let line = lines[index]
            let lineNumber = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { index += 1 }

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
                    append(.code, codeLines.joined(separator: "\n"), lineNumber)
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
                    append(.space, "", lineNumber)
                }
                continue
            }

            if let heading = heading(in: trimmed) {
                flushParagraph()
                append(.heading(level: heading.level), heading.content, lineNumber)
            } else if isDivider(trimmed) {
                flushParagraph()
                append(.divider, "", lineNumber)
            } else if InlineAnnotationMarkdown.isHeading(trimmed) {
                flushParagraph()
                isInsideAnnotation = true
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                let content = String(trimmed.dropFirst())
                    .trimmingCharacters(in: .whitespaces)
                append(.quote, content, lineNumber)
            } else if let table = table(at: index, in: lines) {
                flushParagraph()
                append(.table(header: table.header, rows: table.rows), "", lineNumber)
                index = table.endIndex - 1
            } else if let item = unorderedItem(in: line) {
                flushParagraph()
                if let task = taskItem(in: item.content) {
                    append(
                        .taskList(indentation: item.indentation, isChecked: task.isChecked),
                        task.content,
                        lineNumber
                    )
                } else {
                    append(.unorderedList(indentation: item.indentation), item.content, lineNumber)
                }
            } else if let item = orderedItem(in: line) {
                flushParagraph()
                append(
                    .orderedList(
                        marker: item.marker,
                        indentation: item.indentation
                    ),
                    item.content,
                    lineNumber
                )
            } else if isImageLine(trimmed) {
                flushParagraph()
                append(.image, trimmed, lineNumber)
            } else {
                paragraphLines.append(line)
                paragraphLineNumbers.append(lineNumber)
            }
        }

        flushParagraph()
        flushAnnotation()
        if isInsideCodeFence && !codeLines.isEmpty {
            append(.code, codeLines.joined(separator: "\n"), lines.count)
        }
        while blocks.last.map({ isSpace($0.kind) }) ?? false {
            blocks.removeLast()
        }
        return blocks
    }

    private static func table(
        at startIndex: Int,
        in lines: [String]
    ) -> (header: [String], rows: [[String]], endIndex: Int)? {
        guard startIndex + 1 < lines.count else { return nil }
        let headerLine = lines[startIndex].trimmingCharacters(in: .whitespaces)
        let separatorLine = lines[startIndex + 1]
            .trimmingCharacters(in: .whitespaces)
        guard isTableRow(headerLine), isTableSeparator(separatorLine) else {
            return nil
        }

        var rowLines = [headerLine]
        var cursor = startIndex + 2
        while cursor < lines.count,
              isTableRow(lines[cursor].trimmingCharacters(in: .whitespaces)) {
            rowLines.append(lines[cursor].trimmingCharacters(in: .whitespaces))
            cursor += 1
        }
        let header = tableCells(headerLine)
        let rows = rowLines.dropFirst().map(tableCells)
        return (header, rows, cursor)
    }

    private static func isTableRow(_ line: String) -> Bool {
        line.hasPrefix("|") && line.count > 1
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let compact = cell.replacingOccurrences(of: " ", with: "")
            guard compact.hasPrefix(":") || compact.hasSuffix(":") else {
                return !compact.isEmpty && compact.allSatisfy { $0 == "-" }
            }
            let dashes = compact
                .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return !dashes.isEmpty && dashes.allSatisfy { $0 == "-" }
        }
    }

    private static func tableCells(_ row: String) -> [String] {
        var trimmed = row
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func taskItem(
        in content: String
    ) -> (isChecked: Bool, content: String)? {
        guard content.hasPrefix("[ ]") || content.hasPrefix("[x]")
            || content.hasPrefix("[X]") else { return nil }
        let isChecked = !content.hasPrefix("[ ]")
        let remainder = content.dropFirst(3)
        guard remainder.first?.isWhitespace == true else { return nil }
        return (isChecked, remainder.trimmingCharacters(in: .whitespaces))
    }

    private static func isImageLine(_ line: String) -> Bool {
        guard line.hasPrefix("![") else { return false }
        guard let altEnd = line.range(of: "]") else { return false }
        let remainder = line[altEnd.upperBound...]
        guard remainder.hasPrefix("("), remainder.hasSuffix(")") else { return false }
        let path = remainder.dropFirst().dropLast()
        return !path.trimmingCharacters(in: .whitespaces).isEmpty
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
