import AppKit
import SwiftUI

private struct EditorLink {
    let range: NSRange
    let url: URL
}

private final class EditorTextView: NSTextView {
    var links: [EditorLink] = []

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let lm = layoutManager,
              let tc = textContainer,
              !links.isEmpty else { return }
        for link in links {
            let glyphRange = lm.glyphRange(
                forCharacterRange: link.range,
                actualCharacterRange: nil
            )
            let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            if !rect.isEmpty {
                addCursorRect(rect, cursor: .pointingHand)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if let link = links.first(where: { NSLocationInRange(index, $0.range) }) {
            NSWorkspace.shared.open(link.url)
            return
        }
        super.mouseDown(with: event)
    }
}

struct MarkdownSourceEditor: NSViewRepresentable {
    @Binding var text: String
    let documentID: String
    let onChange: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, documentID: documentID, onChange: onChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = EditorTextView(frame: .zero)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainerInset = NSSize(width: 22, height: 24)
        textView.textContainer?.lineFragmentPadding = 8
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(
            MarkdownSyntaxHighlighter.attributedString(text)
        )
        textView.typingAttributes = MarkdownSyntaxHighlighter.baseAttributes
        textView.links = MarkdownSyntaxHighlighter.collectLinks(in: text)
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        let ruler = MarkdownLineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onChange = onChange
        guard let textView = scrollView.documentView as? EditorTextView else { return }

        let switchedDocument = context.coordinator.documentID != documentID
        guard switchedDocument || textView.string != text else { return }
        context.coordinator.replaceContents(
            of: textView,
            with: text,
            documentID: documentID,
            resetEditingPosition: switchedDocument
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var documentID: String
        var onChange: () -> Void
        private var isApplyingProgrammaticChange = false

        init(
            text: Binding<String>,
            documentID: String,
            onChange: @escaping () -> Void
        ) {
            self.text = text
            self.documentID = documentID
            self.onChange = onChange
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingProgrammaticChange,
                  let textView = notification.object as? EditorTextView else { return }
            let latestText = textView.string
            if text.wrappedValue != latestText {
                text.wrappedValue = latestText
                onChange()
            }
            textView.links = MarkdownSyntaxHighlighter.collectLinks(in: latestText)
            if let window = textView.window {
                window.invalidateCursorRects(for: textView)
            }
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }

        fileprivate func replaceContents(
            of textView: EditorTextView,
            with newText: String,
            documentID newDocumentID: String,
            resetEditingPosition: Bool
        ) {
            isApplyingProgrammaticChange = true
            defer { isApplyingProgrammaticChange = false }

            let replace = {
                textView.textStorage?.setAttributedString(
                    MarkdownSyntaxHighlighter.attributedString(newText)
                )
                textView.typingAttributes = MarkdownSyntaxHighlighter.baseAttributes
                textView.links = MarkdownSyntaxHighlighter.collectLinks(in: newText)
            }

            if resetEditingPosition {
                replace()
                textView.breakUndoCoalescing()
                textView.undoManager?.removeAllActions()
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                textView.scrollToBeginningOfDocument(nil)
            } else {
                Self.preserveEditingState(of: textView, changes: replace)
            }

            documentID = newDocumentID
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }

        static func preserveEditingState(
            of textView: NSTextView,
            changes: () -> Void
        ) {
            let selectedRanges = textView.selectedRanges
            let selectionAffinity = textView.selectionAffinity
            let visibleOrigin = textView.enclosingScrollView?.contentView.bounds.origin
            changes()

            let textLength = textView.string.utf16.count
            let validRanges = selectedRanges.map { value -> NSValue in
                let range = value.rangeValue
                let location = min(range.location, textLength)
                let length = min(range.length, textLength - location)
                return NSValue(range: NSRange(location: location, length: length))
            }
            if textView.selectedRanges != validRanges {
                textView.setSelectedRanges(
                    validRanges,
                    affinity: selectionAffinity,
                    stillSelecting: false
                )
            }

            if let scrollView = textView.enclosingScrollView, let visibleOrigin {
                let documentHeight = textView.frame.height
                let viewportHeight = scrollView.contentView.bounds.height
                let maximumY = max(0, documentHeight - viewportHeight)
                scrollView.contentView.scroll(
                    to: NSPoint(x: visibleOrigin.x, y: min(visibleOrigin.y, maximumY))
                )
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }
}

@MainActor
enum MarkdownSyntaxHighlighter {
    private static let baseFont = NSFont.monospacedSystemFont(
        ofSize: 15,
        weight: .regular
    )

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraphStyle]
    }

    private static var paragraphStyle: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 5
        p.paragraphSpacing = 1
        p.minimumLineHeight = 21
        return p
    }

    // MARK: - Full attributed string (used for initial load / document switch)

    static func attributedString(_ source: String) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: source,
            attributes: [.font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraphStyle]
        )
        let string = source as NSString
        var location = 0
        var inFence = false
        while location < string.length {
            let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
            let line = string.substring(with: lineRange).trimmingCharacters(in: .newlines)
            let cr = NSRange(location: lineRange.location, length: (line as NSString).length)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                result.addAttributes([.foregroundColor: NSColor.systemPurple, .backgroundColor: NSColor.systemPurple.withAlphaComponent(0.07)], range: cr)
            } else if inFence {
                result.addAttributes([.foregroundColor: NSColor.systemTeal, .backgroundColor: NSColor.controlBackgroundColor], range: cr)
            } else {
                styleMarkdownLine(line, range: cr, in: result)
            }
            location = NSMaxRange(lineRange)
        }
        styleInlineMarkdown(in: result, source: source)
        return result
    }

    // MARK: - Shared helpers

    fileprivate static func collectLinks(in source: String) -> [EditorLink] {
        let pattern = #"\[[^\]\n]+\]\(([^)]+)\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsSource = source as NSString
        var links: [EditorLink] = []
        expression.enumerateMatches(in: source, range: NSRange(location: 0, length: (source as NSString).length)) { match, _, _ in
            guard let match, match.numberOfRanges >= 2 else { return }
            let urlString = nsSource.substring(with: match.range(at: 1))
            guard let url = URL(string: urlString) ?? URL(string: "https://\(urlString)") else {
                return
            }
            links.append(EditorLink(range: match.range, url: url))
        }
        return links
    }

    private static func styleMarkdownLine(
        _ line: String, range: NSRange,
        in result: NSMutableAttributedString
    ) {
        if let heading = firstMatch(#"^\s*(#{1,6})\s+"#, in: line) {
            let level = (line as NSString).substring(with: heading.range(at: 1)).count
            result.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: max(15, 20 - CGFloat(level)), weight: .bold),
                .foregroundColor: NSColor.systemBlue
            ], range: range)
            if level == 1 {
                result.addAttribute(.backgroundColor, value: NSColor.systemBlue.withAlphaComponent(0.055), range: range)
            }
            return
        }
        if firstMatch(#"^\s*>\s?"#, in: line) != nil {
            result.addAttributes([.font: italicMonospacedFont(size: 15), .foregroundColor: NSColor.systemGreen], range: range)
            return
        }
        if firstMatch(#"^\s*((-{3,})|(\*{3,})|(_{3,}))\s*$"#, in: line) != nil {
            result.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.systemBlue], range: range)
            return
        }
        if let marker = firstMatch(#"^\s*([-+*]|\d+[.)])(?=\s)"#, in: line) {
            result.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.systemOrange], range: NSRange(location: range.location + marker.range.location, length: marker.range.length))
        }
    }

    private static func styleInlineMarkdown(in result: NSMutableAttributedString, source: String) {
        addStyle(pattern: #"`[^`\n]+`"#, attributes: [.foregroundColor: NSColor.systemPurple, .backgroundColor: NSColor.systemPurple.withAlphaComponent(0.07)], to: result, source: source)
        addStyle(pattern: #"\*\*[^*\n]+\*\*|__[^_\n]+__"#, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .bold)], to: result, source: source)
        styleLinks(in: result, source: source)
    }

    private static func styleLinks(in result: NSMutableAttributedString, source: String) {
        let pattern = #"\[[^\]\n]+\]\(([^)]+)\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        let nsSource = source as NSString
        expression.enumerateMatches(in: source, range: NSRange(location: 0, length: nsSource.length)) { match, _, _ in
            guard let match, match.numberOfRanges >= 2 else { return }
            result.addAttributes(
                [
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ],
                range: match.range
            )
        }
    }

    private static func addStyle(pattern: String, attributes: [NSAttributedString.Key: Any], to result: NSMutableAttributedString, source: String) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        expression.enumerateMatches(in: source, range: NSRange(location: 0, length: (source as NSString).length)) { match, _, _ in
            guard let match else { return }
            result.addAttributes(attributes, range: match.range)
        }
    }

    private static func firstMatch(_ pattern: String, in string: String) -> NSTextCheckingResult? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        return expression.firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length))
    }

    private static func italicMonospacedFont(size: CGFloat) -> NSFont {
        NSFontManager.shared.convert(NSFont.monospacedSystemFont(ofSize: size, weight: .medium), toHaveTrait: .italicFontMask)
    }
}

private final class MarkdownLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 48
        if let clipView = textView.enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrollBoundsDidChange(_:)), name: NSView.boundsDidChangeNotification, object: clipView)
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func scrollBoundsDidChange(_ notification: Notification) { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        let visibleRect = textView.visibleRect
        let string = textView.string as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]
        var lineNumber = 1, location = 0
        repeat {
            let lineRange = string.lineRange(for: NSRange(location: min(location, string.length), length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            if glyphRange.location < layoutManager.numberOfGlyphs {
                let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                let y = fragment.minY + textView.textContainerOrigin.y
                if y + fragment.height >= visibleRect.minY && y <= visibleRect.maxY {
                    let label = "\(lineNumber)" as NSString
                    let point = convert(NSPoint(x: 0, y: y + 2), from: textView)
                    label.draw(at: NSPoint(x: bounds.maxX - label.size(withAttributes: attrs).width - 10, y: point.y), withAttributes: attrs)
                }
            }
            lineNumber += 1
            if lineRange.length == 0 || NSMaxRange(lineRange) >= string.length { break }
            location = NSMaxRange(lineRange)
        } while location <= string.length
    }
}
