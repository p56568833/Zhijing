import AppKit

final class MarkdownLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var lineRanges: [NSRange] = []
    private var cachedStringLength = -1

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification,
            object: textView
        )
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

    @objc private func textDidChange(_ notification: Notification) {
        lineRanges.removeAll(keepingCapacity: true)
        cachedStringLength = -1
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        let visibleRect = textView.visibleRect
        let string = textView.string as NSString
        let ranges = cachedLineRanges(for: string)
        guard !ranges.isEmpty else { return }

        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleRect,
            in: textContainer
        )
        let visibleCharacterRange = layoutManager.characterRange(
            forGlyphRange: visibleGlyphRange,
            actualGlyphRange: nil
        )
        let firstLine = max(
            0,
            lineIndex(containing: visibleCharacterRange.location, in: ranges) - 1
        )
        let visibleUpperBound = NSMaxRange(visibleCharacterRange)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        for index in firstLine..<ranges.count {
            let lineRange = ranges[index]
            if lineRange.location > visibleUpperBound { break }
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
                    let label = "\(index + 1)" as NSString
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
        }
    }

    private func cachedLineRanges(for string: NSString) -> [NSRange] {
        if cachedStringLength == string.length, !lineRanges.isEmpty {
            return lineRanges
        }

        var ranges: [NSRange] = []
        var location = 0
        repeat {
            let range = string.lineRange(
                for: NSRange(location: min(location, string.length), length: 0)
            )
            ranges.append(range)
            if range.length == 0 || NSMaxRange(range) >= string.length {
                break
            }
            location = NSMaxRange(range)
        } while location <= string.length

        lineRanges = ranges
        cachedStringLength = string.length
        return ranges
    }

    private func lineIndex(containing location: Int, in ranges: [NSRange]) -> Int {
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if NSMaxRange(ranges[middle]) <= location {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return min(lower, max(0, ranges.count - 1))
    }
}
