import AppKit

@MainActor
final class MarkdownTextMarkSyntaxVisibilityController: NSObject,
    @preconcurrency NSLayoutManagerDelegate {
    private weak var layoutManager: NSLayoutManager?
    private(set) var hiddenRanges: [NSRange] = []
    /// 排好序的隐藏区间，isHidden 走二分；字形生成回调对每个
    /// 字形都会调用，线性扫全部区间在大文档上是千万级比较。
    private var sortedHiddenRanges: [NSRange] = []

    func connect(to layoutManager: NSLayoutManager) {
        self.layoutManager = layoutManager
        layoutManager.delegate = self
    }

    func updateHiddenRanges(
        _ newRanges: [NSRange],
        textLength: Int
    ) {
        guard hiddenRanges != newRanges else { return }
        let oldRanges = hiddenRanges
        hiddenRanges = newRanges
        sortedHiddenRanges = newRanges
            .filter { $0.length > 0 }
            .sorted { $0.location < $1.location }
        // 批注摘录行里可能嵌标记语法，区间会重叠；合并后二分才成立。
        var merged: [NSRange] = []
        merged.reserveCapacity(sortedHiddenRanges.count)
        for range in sortedHiddenRanges {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        sortedHiddenRanges = merged

        let fullRange = NSRange(location: 0, length: max(0, textLength))
        guard let invalidatedRange = union(of: oldRanges + newRanges).map({
            NSIntersectionRange($0, fullRange)
        }), invalidatedRange.length > 0,
        let layoutManager else { return }

        layoutManager.invalidateGlyphs(
            forCharacterRange: invalidatedRange,
            changeInLength: 0,
            actualCharacterRange: nil
        )
        layoutManager.invalidateLayout(
            forCharacterRange: invalidatedRange,
            actualCharacterRange: nil
        )
        layoutManager.invalidateDisplay(forCharacterRange: invalidatedRange)
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font aFont: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard !hiddenRanges.isEmpty else { return 0 }

        var glyphBuffer = Array(UnsafeBufferPointer(
            start: glyphs,
            count: glyphRange.length
        ))
        var propertyBuffer = Array(UnsafeBufferPointer(
            start: props,
            count: glyphRange.length
        ))
        let characterBuffer = Array(UnsafeBufferPointer(
            start: charIndexes,
            count: glyphRange.length
        ))
        var changed = false

        for index in glyphBuffer.indices where isHidden(characterBuffer[index]) {
            glyphBuffer[index] = 0
            propertyBuffer[index].insert(.null)
            changed = true
        }
        guard changed else { return 0 }

        glyphBuffer.withUnsafeBufferPointer { glyphPointer in
            propertyBuffer.withUnsafeBufferPointer { propertyPointer in
                characterBuffer.withUnsafeBufferPointer { characterPointer in
                    layoutManager.setGlyphs(
                        glyphPointer.baseAddress!,
                        properties: propertyPointer.baseAddress!,
                        characterIndexes: characterPointer.baseAddress!,
                        font: aFont,
                        forGlyphRange: glyphRange
                    )
                }
            }
        }
        return glyphRange.length
    }

    private func isHidden(_ characterIndex: Int) -> Bool {
        var low = 0
        var high = sortedHiddenRanges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = sortedHiddenRanges[mid]
            if characterIndex < range.location {
                high = mid - 1
            } else if characterIndex >= NSMaxRange(range) {
                low = mid + 1
            } else {
                return true
            }
        }
        return false
    }

    private func union(of ranges: [NSRange]) -> NSRange? {
        let validRanges = ranges.filter { $0.length > 0 }
        guard let first = validRanges.first else { return nil }
        return validRanges.dropFirst().reduce(first, NSUnionRange)
    }
}
