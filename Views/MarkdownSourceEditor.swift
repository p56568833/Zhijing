import AppKit
import SwiftUI

final class MarkdownEditorTextView: NSTextView {
    var markdownLinks: [MarkdownEditorLink] = []
    var onAIEditAction: ((AISelectionEditAction) -> Void)?
    var onFindCommand: ((DocumentFindCommand) -> Void)?
    private var linkTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let linkTrackingArea {
            removeTrackingArea(linkTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [
                .inVisibleRect,
                .activeInKeyWindow,
                .mouseMoved,
                .mouseEnteredAndExited,
                .cursorUpdate
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        linkTrackingArea = trackingArea
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let layoutManager,
              let textContainer,
              !markdownLinks.isEmpty else { return }

        for link in markdownLinks {
            for rect in cursorRects(
                for: link.range,
                layoutManager: layoutManager,
                textContainer: textContainer
            ) {
                addCursorRect(
                    rect.insetBy(dx: -1, dy: 0),
                    cursor: .pointingHand
                )
            }
        }
    }

    func cursorRects(
        for characterRange: NSRange,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> [NSRect] {
        let targetGlyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        var rects: [NSRect] = []
        layoutManager.enumerateLineFragments(
            forGlyphRange: targetGlyphRange
        ) { _, _, _, lineGlyphRange, _ in
            let intersection = NSIntersectionRange(
                targetGlyphRange,
                lineGlyphRange
            )
            guard intersection.length > 0 else { return }
            var rect = layoutManager.boundingRect(
                forGlyphRange: intersection,
                in: textContainer
            )
            rect.origin.x += self.textContainerOrigin.x
            rect.origin.y += self.textContainerOrigin.y
            if !rect.isEmpty {
                rects.append(rect)
            }
        }
        return rects
    }

    func markdownLink(at point: NSPoint) -> MarkdownEditorLink? {
        guard let layoutManager,
              let textContainer else { return nil }
        let containerPoint = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint,
            in: textContainer
        )
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard let candidate = markdownLinks.first(where: { link in
            NSLocationInRange(characterIndex, link.range)
        }) else { return nil }
        return cursorRects(
            for: candidate.range,
            layoutManager: layoutManager,
            textContainer: textContainer
        ).contains { rect in
            rect.insetBy(dx: -1, dy: 0).contains(point)
        } ? candidate : nil
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(for: event)
    }

    override func mouseEntered(with event: NSEvent) {
        updateCursor(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    private func updateCursor(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if markdownLink(at: point) != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let link = markdownLink(at: point) {
            NSWorkspace.shared.open(link.url)
            return
        }
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command),
              let characters = event.charactersIgnoringModifiers?.lowercased()
        else {
            return super.performKeyEquivalent(with: event)
        }

        if characters == "f" {
            onFindCommand?(.show)
            return true
        }
        if characters == "g" {
            onFindCommand?(modifiers.contains(.shift) ? .previous : .next)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard selectedRange().length > 0 else { return menu }
        menu.addItem(.separator())
        let parent = NSMenuItem(
            title: "AI 修改所选内容",
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu(title: "AI 修改所选内容")
        for action in AISelectionEditAction.allCases {
            let item = NSMenuItem(
                title: action.title,
                action: #selector(performAISelectionEdit(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = action.rawValue
            submenu.addItem(item)
            if action == .logic {
                submenu.addItem(.separator())
            }
        }
        parent.submenu = submenu
        menu.addItem(parent)
        return menu
    }

    @objc private func performAISelectionEdit(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let action = AISelectionEditAction(rawValue: rawValue) else { return }
        onAIEditAction?(action)
    }
}

struct MarkdownSourceEditor: NSViewRepresentable {
    let text: String
    let documentID: String
    let contentRevision: Int
    let navigationRequest: EditorNavigationRequest?
    let findOptions: DocumentFindOptions
    let findNavigationRequest: DocumentFindNavigationRequest?
    let onChange: (String) -> Void
    let onSelectionChange: (EditorTextSelection?) -> Void
    let onFindResultChange: (DocumentFindResult) -> Void
    let onFindCommand: (DocumentFindCommand) -> Void
    let onAIEditAction: (AISelectionEditAction) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onChange: onChange,
            onSelectionChange: onSelectionChange,
            onFindResultChange: onFindResultChange
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = makeScrollView()
        let textView = makeTextView(in: scrollView)
        textView.delegate = context.coordinator
        textView.onAIEditAction = onAIEditAction
        textView.onFindCommand = onFindCommand
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
        context.coordinator.navigate(
            to: navigationRequest,
            in: textView
        )
        context.coordinator.updateFind(
            options: findOptions,
            navigationRequest: findNavigationRequest,
            in: textView
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onFindResultChange = onFindResultChange
        guard let textView = scrollView.documentView as? MarkdownEditorTextView else {
            return
        }
        textView.onAIEditAction = onAIEditAction
        textView.onFindCommand = onFindCommand
        context.coordinator.synchronize(
            text: text,
            documentID: documentID,
            contentRevision: contentRevision,
            to: textView
        )
        context.coordinator.navigate(
            to: navigationRequest,
            in: textView
        )
        context.coordinator.updateFind(
            options: findOptions,
            navigationRequest: findNavigationRequest,
            in: textView
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
        var onSelectionChange: (EditorTextSelection?) -> Void
        var onFindResultChange: (DocumentFindResult) -> Void
        private(set) var documentID: String?
        private(set) var contentRevision: Int?
        private var navigationRequestID: UUID?
        private var findNavigationRequestID: UUID?
        private var isApplyingExternalContent = false
        private var presentationWork: DispatchWorkItem?
        private var tabStates: [String: TabEditorState] = [:]
        private var findOptions = DocumentFindOptions()
        private var findMatches: [NSRange] = []
        private var selectedFindIndex: Int?
        private var highlightedFindRanges: [NSRange] = []
        private var lastFindSource: String?

        private struct TabEditorState {
            let selection: NSRange
            let visibleOrigin: NSPoint
        }

        init(
            onChange: @escaping (String) -> Void,
            onSelectionChange: @escaping (EditorTextSelection?) -> Void = { _ in },
            onFindResultChange: @escaping (DocumentFindResult) -> Void = { _ in }
        ) {
            self.onChange = onChange
            self.onSelectionChange = onSelectionChange
            self.onFindResultChange = onFindResultChange
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalContent,
                  let textView = notification.object as? MarkdownEditorTextView else {
                return
            }
            schedulePresentationUpdate(for: textView)
            updateFind(
                options: findOptions,
                navigationRequest: nil,
                in: textView
            )
            onChange(textView.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingExternalContent,
                  let textView = notification.object as? MarkdownEditorTextView,
                  let documentID else { return }
            let range = textView.selectedRange()
            guard range.length > 0,
                  NSMaxRange(range) <= (textView.string as NSString).length else {
                onSelectionChange(nil)
                return
            }
            onSelectionChange(EditorTextSelection(
                documentID: documentID,
                range: range,
                text: (textView.string as NSString).substring(with: range)
            ))
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
                if let documentID {
                    tabStates[documentID] = TabEditorState(
                        selection: textView.selectedRange(),
                        visibleOrigin: textView.enclosingScrollView?
                            .contentView.bounds.origin ?? .zero
                    )
                }
                replaceText(in: textView, with: text)
                textView.breakUndoCoalescing()
                textView.undoManager?.removeAllActions()
                if let state = tabStates[newDocumentID] {
                    let length = (text as NSString).length
                    let location = min(state.selection.location, length)
                    let selection = NSRange(
                        location: location,
                        length: min(state.selection.length, length - location)
                    )
                    textView.setSelectedRange(selection)
                    if let scrollView = textView.enclosingScrollView {
                        scrollView.contentView.scroll(to: state.visibleOrigin)
                        scrollView.reflectScrolledClipView(scrollView.contentView)
                    }
                } else {
                    textView.setSelectedRange(NSRange(location: 0, length: 0))
                    textView.scrollToBeginningOfDocument(nil)
                }
            } else {
                preserveViewportAndSelection(of: textView) {
                    replaceText(in: textView, with: text)
                }
            }

            documentID = newDocumentID
            contentRevision = newContentRevision
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }

        func navigate(
            to request: EditorNavigationRequest?,
            in textView: MarkdownEditorTextView
        ) {
            guard let request,
                  request.documentID == documentID,
                  request.id != navigationRequestID else { return }
            navigationRequestID = request.id

            let source = textView.string as NSString
            guard source.length > 0 else { return }
            if let requestedRange = request.selectionRange {
                let safeRange = NSIntersectionRange(
                    requestedRange,
                    NSRange(location: 0, length: source.length)
                )
                textView.setSelectedRange(safeRange)
                textView.scrollRangeToVisible(safeRange)
                textView.centerSelectionInVisibleArea(nil)
                textView.showFindIndicator(for: safeRange)
                textView.window?.makeFirstResponder(textView)
                return
            }
            guard let requestedLine = request.line else { return }
            let targetLine = max(1, requestedLine)
            var currentLine = 1
            var location = 0
            while currentLine < targetLine, location < source.length {
                let range = source.lineRange(
                    for: NSRange(location: location, length: 0)
                )
                location = NSMaxRange(range)
                currentLine += 1
            }
            guard location <= source.length else { return }

            let lineRange = source.lineRange(
                for: NSRange(location: min(location, source.length), length: 0)
            )
            let visibleLength = max(
                0,
                lineRange.length - (
                    NSMaxRange(lineRange) <= source.length &&
                    source.substring(with: lineRange).hasSuffix("\n") ? 1 : 0
                )
            )
            let selection = NSRange(
                location: lineRange.location,
                length: visibleLength
            )
            textView.setSelectedRange(selection)
            if let verticalFraction = request.verticalFraction {
                position(
                    selection,
                    at: verticalFraction,
                    in: textView
                )
            } else {
                textView.scrollRangeToVisible(selection)
                textView.centerSelectionInVisibleArea(nil)
            }
            textView.showFindIndicator(for: selection)
            textView.window?.makeFirstResponder(textView)
        }

        private func position(
            _ characterRange: NSRange,
            at verticalFraction: Double,
            in textView: NSTextView
        ) {
            guard let scrollView = textView.enclosingScrollView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            let lineRect = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            )
            let visibleBounds = scrollView.contentView.bounds
            let fraction = max(0, min(1, verticalFraction))
            let targetY = textView.textContainerOrigin.y + lineRect.midY
                - visibleBounds.height * fraction
            let maximumY = max(0, textView.frame.height - visibleBounds.height)
            scrollView.contentView.scroll(to: NSPoint(
                x: visibleBounds.minX,
                y: max(0, min(targetY, maximumY))
            ))
            scrollView.reflectScrolledClipView(scrollView.contentView)
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
            let links = MarkdownLinkDetector.links(in: textView.string)
            updateLinks(links, in: textView)
            MarkdownPresentationHighlighter.apply(to: textView, links: links)
            updateFind(
                options: findOptions,
                navigationRequest: nil,
                in: textView
            )
        }

        private func updateLinks(
            _ links: [MarkdownEditorLink],
            in textView: MarkdownEditorTextView
        ) {
            textView.markdownLinks = links
            if let window = textView.window {
                window.invalidateCursorRects(for: textView)
            }
        }

        private func schedulePresentationUpdate(
            for textView: MarkdownEditorTextView
        ) {
            presentationWork?.cancel()
            let work = DispatchWorkItem { [weak textView] in
                guard let textView,
                      !textView.hasMarkedText() else { return }
                let links = MarkdownLinkDetector.links(in: textView.string)
                self.updateLinks(links, in: textView)
                MarkdownPresentationHighlighter.apply(
                    to: textView,
                    links: links,
                    characterRange: self.visibleCharacterRange(in: textView)
                )
                self.applyFindHighlights(in: textView)
                textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            }
            presentationWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.18,
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

        func updateFind(
            options newOptions: DocumentFindOptions,
            navigationRequest: DocumentFindNavigationRequest?,
            in textView: MarkdownEditorTextView
        ) {
            let source = textView.string
            let optionsChanged = newOptions != findOptions
            let sourceChanged = source != lastFindSource

            if optionsChanged || sourceChanged {
                findOptions = newOptions
                lastFindSource = source
                findMatches = DocumentFindMatcher.matches(
                    in: source,
                    options: newOptions
                )
                selectedFindIndex = selectedIndexNearSelection(in: textView)
            }

            let shouldNavigate = navigationRequest.map {
                $0.id != findNavigationRequestID
            } ?? false
            if let navigationRequest, shouldNavigate {
                findNavigationRequestID = navigationRequest.id
                moveFindSelection(
                    navigationRequest.direction,
                    in: textView,
                    focusEditor: true
                )
            } else if optionsChanged, !findMatches.isEmpty {
                selectFindMatch(
                    selectedFindIndex ?? 0,
                    in: textView,
                    focusEditor: false
                )
            }

            applyFindHighlights(in: textView)
            reportFindResult()
        }

        private func selectedIndexNearSelection(in textView: NSTextView) -> Int? {
            guard !findMatches.isEmpty else { return nil }
            let selection = textView.selectedRange()
            if let exact = findMatches.firstIndex(where: { $0 == selection }) {
                return exact
            }
            if let next = findMatches.firstIndex(where: {
                $0.location >= selection.location
            }) {
                return next
            }
            return 0
        }

        private func moveFindSelection(
            _ direction: DocumentFindDirection,
            in textView: MarkdownEditorTextView,
            focusEditor: Bool
        ) {
            guard !findMatches.isEmpty else { return }
            let current = selectedFindIndex ?? selectedIndexNearSelection(in: textView) ?? 0
            let nextIndex: Int
            switch direction {
            case .previous:
                nextIndex = (current - 1 + findMatches.count) % findMatches.count
            case .next:
                nextIndex = (current + 1) % findMatches.count
            }
            selectFindMatch(nextIndex, in: textView, focusEditor: focusEditor)
        }

        private func selectFindMatch(
            _ index: Int,
            in textView: NSTextView,
            focusEditor: Bool
        ) {
            guard findMatches.indices.contains(index) else { return }
            selectedFindIndex = index
            let range = findMatches[index]
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            textView.centerSelectionInVisibleArea(nil)
            textView.showFindIndicator(for: range)
            if focusEditor {
                textView.window?.makeFirstResponder(textView)
            }
        }

        private func applyFindHighlights(in textView: NSTextView) {
            guard let layoutManager = textView.layoutManager else { return }
            let oldRanges = highlightedFindRanges
            highlightedFindRanges = findMatches

            for range in oldRanges where range.length > 0 {
                layoutManager.removeTemporaryAttribute(
                    .backgroundColor,
                    forCharacterRange: range
                )
                layoutManager.removeTemporaryAttribute(
                    .underlineStyle,
                    forCharacterRange: range
                )
            }

            if let restoreRange = unionRange(oldRanges) {
                MarkdownPresentationHighlighter.apply(
                    to: textView,
                    links: (textView as? MarkdownEditorTextView)?.markdownLinks ?? [],
                    characterRange: restoreRange
                )
            }

            for (index, range) in findMatches.enumerated() where range.length > 0 {
                let isCurrent = index == selectedFindIndex
                layoutManager.addTemporaryAttributes(
                    [
                        .backgroundColor: isCurrent
                            ? NSColor.systemOrange.withAlphaComponent(0.34)
                            : NSColor.systemYellow.withAlphaComponent(0.25),
                        .underlineStyle: isCurrent
                            ? NSUnderlineStyle.single.rawValue
                            : 0
                    ],
                    forCharacterRange: range
                )
            }
        }

        private func unionRange(_ ranges: [NSRange]) -> NSRange? {
            let valid = ranges.filter { $0.length > 0 }
            guard let first = valid.first else { return nil }
            return valid.dropFirst().reduce(first) { result, range in
                NSUnionRange(result, range)
            }
        }

        private func reportFindResult() {
            onFindResultChange(DocumentFindResult(
                matchCount: findMatches.count,
                selectedIndex: selectedFindIndex
            ))
        }

        private func visibleCharacterRange(in textView: NSTextView) -> NSRange? {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return nil }
            let visibleRect = textView.visibleRect.insetBy(dx: 0, dy: -900)
            let glyphRange = layoutManager.glyphRange(
                forBoundingRect: visibleRect,
                in: textContainer
            )
            let characterRange = layoutManager.characterRange(
                forGlyphRange: glyphRange,
                actualGlyphRange: nil
            )
            let fullRange = NSRange(location: 0, length: textView.string.utf16.count)
            let safeRange = NSIntersectionRange(characterRange, fullRange)
            return safeRange.length > 0 ? safeRange : nil
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
