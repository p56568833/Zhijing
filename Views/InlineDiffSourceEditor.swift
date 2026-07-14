import AppKit
import SwiftUI

final class InlineDiffTextView: NSTextView {
    var decorations: [InlineDiffDecoration] = [] {
        didSet { needsDisplay = true }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer else { return }

        for decoration in decorations {
            let lineRange = effectiveLineRange(for: decoration.range)
            guard lineRange.location <= string.utf16.count else { continue }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: lineRange,
                actualCharacterRange: nil
            )
            guard glyphRange.location < layoutManager.numberOfGlyphs else { continue }

            layoutManager.enumerateLineFragments(
                forGlyphRange: glyphRange
            ) { _, usedRect, _, fragmentGlyphRange, _ in
                let intersection = NSIntersectionRange(glyphRange, fragmentGlyphRange)
                guard intersection.length > 0 else { return }
                let contentRect = layoutManager.boundingRect(
                    forGlyphRange: intersection,
                    in: textContainer
                )
                let minimumWidth = min(180, max(80, textContainer.containerSize.width * 0.28))
                let highlightRect = NSRect(
                    x: self.textContainerOrigin.x + contentRect.minX - 5,
                    y: self.textContainerOrigin.y + usedRect.minY + 1,
                    width: max(contentRect.width + 10, minimumWidth),
                    height: max(18, usedRect.height - 2)
                )
                guard highlightRect.intersects(rect) else { return }

                let color: NSColor = decoration.kind == .removed
                    ? .systemRed
                    : .systemGreen
                color.withAlphaComponent(0.10).setFill()
                let path = NSBezierPath(roundedRect: highlightRect, xRadius: 4, yRadius: 4)
                path.fill()
                color.withAlphaComponent(0.72).setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }
        }
    }

    private func effectiveLineRange(for range: NSRange) -> NSRange {
        let source = string as NSString
        guard source.length > 0 else { return .init(location: 0, length: 0) }
        let location = min(range.location, source.length - 1)
        return source.lineRange(for: NSRange(location: location, length: 0))
    }
}

struct InlineDiffSourceEditor: NSViewRepresentable {
    let presentation: InlineDiffPresentation
    let proposalID: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentInsets = NSEdgeInsets(
            top: 0,
            left: 0,
            bottom: 72,
            right: 0
        )

        let textView = InlineDiffTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
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
        scrollView.documentView = textView

        let ruler = MarkdownLineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.apply(
            presentation,
            proposalID: proposalID,
            to: textView,
            scrollView: scrollView,
            revealFirstChange: true
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? InlineDiffTextView else {
            return
        }
        context.coordinator.apply(
            presentation,
            proposalID: proposalID,
            to: textView,
            scrollView: scrollView,
            revealFirstChange: context.coordinator.proposalID != proposalID
        )
    }

    @MainActor
    final class Coordinator {
        private(set) var proposalID: UUID?

        func apply(
            _ presentation: InlineDiffPresentation,
            proposalID: UUID,
            to textView: InlineDiffTextView,
            scrollView: NSScrollView,
            revealFirstChange: Bool
        ) {
            guard self.proposalID != proposalID || textView.string != presentation.text else {
                return
            }
            self.proposalID = proposalID
            textView.string = presentation.text
            MarkdownSourceEditor.Coordinator.applyPlainTextAppearance(to: textView)
            MarkdownPresentationHighlighter.apply(to: textView)
            applyDiffAttributes(presentation.decorations, to: textView)
            textView.decorations = presentation.decorations
            scrollView.verticalRulerView?.needsDisplay = true

            if revealFirstChange, let range = presentation.firstChangeRange {
                DispatchQueue.main.async { [weak textView, weak scrollView] in
                    guard let textView, let scrollView else { return }
                    self.reveal(range, in: textView, scrollView: scrollView)
                }
            }
        }

        private func applyDiffAttributes(
            _ decorations: [InlineDiffDecoration],
            to textView: NSTextView
        ) {
            guard let layoutManager = textView.layoutManager else { return }
            for decoration in decorations where decoration.range.length > 0 {
                let color: NSColor = decoration.kind == .removed
                    ? .systemRed
                    : .systemGreen
                var attributes: [NSAttributedString.Key: Any] = [
                    .foregroundColor: color
                ]
                if decoration.kind == .removed {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.strikethroughColor] = color
                }
                layoutManager.addTemporaryAttributes(
                    attributes,
                    forCharacterRange: decoration.range
                )
            }
        }

        private func reveal(
            _ range: NSRange,
            in textView: NSTextView,
            scrollView: NSScrollView
        ) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let sourceLength = textView.string.utf16.count
            guard sourceLength > 0 else { return }
            let safeLocation = min(range.location, sourceLength - 1)
            let safeRange = NSRange(
                location: safeLocation,
                length: max(1, min(range.length, sourceLength - safeLocation))
            )
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: safeRange,
                actualCharacterRange: nil
            )
            let changeRect = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            )
            let clipView = scrollView.contentView
            let targetY = max(
                0,
                textView.textContainerOrigin.y + changeRect.minY
                    - clipView.bounds.height * 0.32
            )
            clipView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(clipView)
        }
    }
}
