import AppKit

final class MarkdownLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(
            scrollView: textView.enclosingScrollView,
            orientation: .verticalRuler
        )
        clientView = textView
        ruleThickness = 48
        if let clipView = textView.enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func scrollBoundsDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(
            x: bounds.maxX - 1,
            y: bounds.minY,
            width: 1,
            height: bounds.height
        ).fill()

        let visibleRect = textView.visibleRect
        let string = textView.string as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        var lineNumber = 1
        var location = 0
        repeat {
            let lineRange = string.lineRange(
                for: NSRange(location: min(location, string.length), length: 0)
            )
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: lineRange,
                actualCharacterRange: nil
            )
            if glyphRange.location < layoutManager.numberOfGlyphs {
                let fragment = layoutManager.lineFragmentRect(
                    forGlyphAt: glyphRange.location,
                    effectiveRange: nil
                )
                let y = fragment.minY + textView.textContainerOrigin.y
                if y + fragment.height >= visibleRect.minY, y <= visibleRect.maxY {
                    let label = "\(lineNumber)" as NSString
                    let point = convert(NSPoint(x: 0, y: y + 2), from: textView)
                    label.draw(
                        at: NSPoint(
                            x: bounds.maxX - label.size(withAttributes: attributes).width - 10,
                            y: point.y
                        ),
                        withAttributes: attributes
                    )
                }
            }
            lineNumber += 1
            if lineRange.length == 0 || NSMaxRange(lineRange) >= string.length {
                break
            }
            location = NSMaxRange(lineRange)
        } while location <= string.length
    }
}
