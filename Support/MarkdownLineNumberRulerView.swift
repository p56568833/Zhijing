import AppKit

struct MarkdownLineNumberMarker: Equatable {
    let lineNumber: Int
    let rectInTextView: NSRect
}

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
        invalidateLineNumberCache()
    }

    func invalidateLineNumberCache() {
        lineRanges.removeAll(keepingCapacity: true)
        cachedStringLength = -1
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView else { return }

        ZhijingTheme.gutterNSColor.setFill()
        bounds.fill()

        ZhijingTheme.hairlineNSColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height)
            .fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        for marker in lineNumberMarkers(in: textView.visibleRect) {
            let label = "\(marker.lineNumber)" as NSString
            let labelSize = label.size(withAttributes: attributes)
            let fragmentRect = convert(marker.rectInTextView, from: textView)
            label.draw(
                at: NSPoint(
                    x: bounds.maxX - labelSize.width - 10,
                    y: fragmentRect.midY - labelSize.height / 2
                ),
                withAttributes: attributes
            )
        }
    }

    func lineNumberMarkers(in visibleRect: NSRect) -> [MarkdownLineNumberMarker] {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return [] }

        layoutManager.ensureLayout(for: textContainer)
        let ranges = cachedLineRanges(for: textView.string as NSString)
        guard !ranges.isEmpty else { return [] }

        let textOrigin = textView.textContainerOrigin
        let visibleContainerRect = visibleRect.offsetBy(
            dx: -textOrigin.x,
            dy: -textOrigin.y
        )
        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleContainerRect,
            in: textContainer
        )
        var markers: [MarkdownLineNumberMarker] = []

        layoutManager.enumerateLineFragments(
            forGlyphRange: visibleGlyphRange
        ) { _, usedRect, _, glyphRange, _ in
            guard glyphRange.location < layoutManager.numberOfGlyphs else { return }
            let characterLocation = layoutManager.characterIndexForGlyph(
                at: glyphRange.location
            )
            let lineIndex = self.lineIndex(
                containing: characterLocation,
                in: ranges
            )

            // A long source line can occupy several visual rows. Its number belongs
            // only to the first fragment; each real blank line still has a fragment.
            guard ranges[lineIndex].location == characterLocation else { return }
            let rectInTextView = usedRect.offsetBy(
                dx: textOrigin.x,
                dy: textOrigin.y
            )
            guard rectInTextView.intersects(visibleRect) else { return }
            markers.append(MarkdownLineNumberMarker(
                lineNumber: lineIndex + 1,
                rectInTextView: rectInTextView
            ))
        }

        if let lastRange = ranges.last,
           lastRange.length == 0,
           lastRange.location == textView.string.utf16.count,
           layoutManager.extraLineFragmentTextContainer === textContainer {
            let extraRect = layoutManager.extraLineFragmentUsedRect.offsetBy(
                dx: textOrigin.x,
                dy: textOrigin.y
            )
            if extraRect.intersects(visibleRect) {
                markers.append(MarkdownLineNumberMarker(
                    lineNumber: ranges.count,
                    rectInTextView: extraRect
                ))
            }
        }

        return markers
    }

    private func cachedLineRanges(for string: NSString) -> [NSRange] {
        if cachedStringLength == string.length, !lineRanges.isEmpty {
            return lineRanges
        }

        var ranges: [NSRange] = []
        var location = 0
        while location < string.length {
            let range = string.lineRange(
                for: NSRange(location: location, length: 0)
            )
            ranges.append(range)
            guard range.length > 0 else { break }
            location = NSMaxRange(range)
        }

        if string.length == 0 || endsWithLineBreak(string) {
            ranges.append(NSRange(location: string.length, length: 0))
        }

        lineRanges = ranges
        cachedStringLength = string.length
        return ranges
    }

    private func endsWithLineBreak(_ string: NSString) -> Bool {
        guard string.length > 0 else { return false }
        return CharacterSet.newlines.contains(
            UnicodeScalar(string.character(at: string.length - 1))!
        )
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
