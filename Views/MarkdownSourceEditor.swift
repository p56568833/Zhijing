import AppKit
import SwiftUI

final class MarkdownEditorTextView: NSTextView {
    var markdownLinks: [MarkdownEditorLink] = []

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let layoutManager,
              let textContainer,
              !markdownLinks.isEmpty else { return }

        for link in markdownLinks {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: link.range,
                actualCharacterRange: nil
            )
            let rect = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            )
            if !rect.isEmpty {
                addCursorRect(rect, cursor: .pointingHand)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if let link = markdownLinks.first(where: {
            NSLocationInRange(index, $0.range)
        }) {
            NSWorkspace.shared.open(link.url)
            return
        }
        super.mouseDown(with: event)
    }
}

struct MarkdownSourceEditor: NSViewRepresentable {
    let text: String
    let documentID: String
    let contentRevision: Int
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = makeScrollView()
        let textView = makeTextView(in: scrollView)
        textView.delegate = context.coordinator
        scrollView.documentView = textView

        let ruler = MarkdownLineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.synchronize(
            text: text,
            documentID: documentID,
            contentRevision: contentRevision,
            to: textView
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onChange = onChange
        guard let textView = scrollView.documentView as? MarkdownEditorTextView else {
            return
        }
        context.coordinator.synchronize(
            text: text,
            documentID: documentID,
            contentRevision: contentRevision,
            to: textView
        )
    }

    private func makeScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    private func makeTextView(in scrollView: NSScrollView) -> MarkdownEditorTextView {
        let textView = MarkdownEditorTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.drawsBackground = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 22, height: 24)
        textView.textContainer?.lineFragmentPadding = 8
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        Coordinator.applyPlainTextAppearance(to: textView)
        return textView
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (String) -> Void
        private(set) var documentID: String?
        private(set) var contentRevision: Int?
        private var isApplyingExternalContent = false
        private var presentationWork: DispatchWorkItem?

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalContent,
                  let textView = notification.object as? MarkdownEditorTextView else {
                return
            }
            updateLinks(in: textView)
            schedulePresentationUpdate(for: textView)
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            onChange(textView.string)
        }

        func synchronize(
            text: String,
            documentID newDocumentID: String,
            contentRevision newContentRevision: Int,
            to textView: MarkdownEditorTextView
        ) {
            let switchedDocument = documentID != newDocumentID
            let changedExternally = contentRevision != newContentRevision
            guard switchedDocument || changedExternally else { return }

            isApplyingExternalContent = true
            defer { isApplyingExternalContent = false }

            if switchedDocument {
                replaceText(in: textView, with: text)
                textView.breakUndoCoalescing()
                textView.undoManager?.removeAllActions()
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                textView.scrollToBeginningOfDocument(nil)
            } else {
                preserveViewportAndSelection(of: textView) {
                    replaceText(in: textView, with: text)
                }
            }

            documentID = newDocumentID
            contentRevision = newContentRevision
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }

        static func applyPlainTextAppearance(to textView: NSTextView) {
            textView.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
            textView.textColor = .labelColor
            textView.defaultParagraphStyle = paragraphStyle
            textView.typingAttributes = baseAttributes
        }

        private func replaceText(
            in textView: MarkdownEditorTextView,
            with text: String
        ) {
            textView.string = text
            Self.applyPlainTextAppearance(to: textView)
            if let textStorage = textView.textStorage, textStorage.length > 0 {
                textStorage.setAttributes(
                    Self.baseAttributes,
                    range: NSRange(location: 0, length: textStorage.length)
                )
            }
            updateLinks(in: textView)
            MarkdownPresentationHighlighter.apply(to: textView)
        }

        private func updateLinks(in textView: MarkdownEditorTextView) {
            textView.markdownLinks = MarkdownLinkDetector.links(in: textView.string)
            if let window = textView.window {
                window.invalidateCursorRects(for: textView)
            }
        }

        private func schedulePresentationUpdate(
            for textView: MarkdownEditorTextView
        ) {
            presentationWork?.cancel()
            let expectedText = textView.string
            let work = DispatchWorkItem { [weak textView] in
                guard let textView,
                      textView.string == expectedText,
                      !textView.hasMarkedText() else { return }
                MarkdownPresentationHighlighter.apply(to: textView)
            }
            presentationWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.08,
                execute: work
            )
        }

        private func preserveViewportAndSelection(
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
            textView.setSelectedRanges(
                validRanges,
                affinity: selectionAffinity,
                stillSelecting: false
            )

            if let scrollView = textView.enclosingScrollView, let visibleOrigin {
                let maximumY = max(
                    0,
                    textView.frame.height - scrollView.contentView.bounds.height
                )
                scrollView.contentView.scroll(
                    to: NSPoint(
                        x: visibleOrigin.x,
                        y: min(visibleOrigin.y, maximumY)
                    )
                )
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        private static var paragraphStyle: NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 5
            style.paragraphSpacing = 1
            style.minimumLineHeight = 21
            return style
        }

        private static var baseAttributes: [NSAttributedString.Key: Any] {
            [
                .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle
            ]
        }
    }
}
