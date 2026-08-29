import Foundation

struct InlineAnnotationInsertion: Equatable, Sendable {
    let range: NSRange
    let replacementText: String
    let cursorLocation: Int
}

enum InlineAnnotationMarkdown {
    static let heading = "> 批注"
    static let legacyHeading = "> **批注**"

    static func isHeading(_ line: String) -> Bool {
        line == heading || line == legacyHeading
    }

    static func insertion(
        in source: String,
        selection: NSRange,
        annotation: String
    ) -> InlineAnnotationInsertion? {
        let nsSource = source as NSString
        let value = annotation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              selection.length > 0,
              NSMaxRange(selection) <= nsSource.length else { return nil }

        let selectedText = nsSource.substring(with: selection)
        let lastSelectedLocation = max(selection.location, NSMaxRange(selection) - 1)
        let selectedLineRange = nsSource.lineRange(
            for: NSRange(location: lastSelectedLocation, length: 0)
        )
        let insertionLocation = NSMaxRange(selectedLineRange)
        let block = render(annotation: value, selectedText: selectedText)

        let hasLeadingNewline = insertionLocation > 0
            && nsSource.character(at: insertionLocation - 1) == 10
        let hasFollowingContent = insertionLocation < nsSource.length
        let leading = hasLeadingNewline ? "\n" : "\n\n"
        let trailing = hasFollowingContent ? "\n\n" : "\n"
        let replacement = leading + block + trailing

        return InlineAnnotationInsertion(
            range: NSRange(location: insertionLocation, length: 0),
            replacementText: replacement,
            cursorLocation: insertionLocation + (replacement as NSString).length
        )
    }

    static func render(annotation: String, selectedText: String) -> String {
        let excerpt = compactExcerpt(selectedText)
        var lines = [heading, "> 原文 · 「\(excerpt)」", ">"]
        lines.append(contentsOf: annotation
            .components(separatedBy: .newlines)
            .map { $0.isEmpty ? ">" : "> \($0)" })
        return lines.joined(separator: "\n")
    }

    private static func compactExcerpt(_ source: String) -> String {
        let compact = source
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let limit = 80
        guard compact.count > limit else { return compact }
        return String(compact.prefix(limit)) + "…"
    }

    /// 编辑器里批注块的「原文」行与其后的空分隔行折叠隐藏，
    /// 返回需要隐藏的字形范围（含换行，折叠后块只剩标题和内容两行）。
    /// 只处理写入口生成的固定格式，手工改写过的行保持原样。
    static func hiddenExcerptRanges(in source: String) -> [NSRange] {
        let nsSource = source as NSString
        var results: [NSRange] = []
        var location = 0
        while location < nsSource.length {
            let headingLineRange = nsSource.lineRange(
                for: NSRange(location: location, length: 0)
            )
            let headingLine = nsSource.substring(with: headingLineRange)
                .trimmingCharacters(in: .newlines)
            if isHeading(headingLine) {
                let excerptRange = nsSource.lineRange(
                    for: NSRange(location: NSMaxRange(headingLineRange), length: 0)
                )
                let excerptLine = nsSource.substring(with: excerptRange)
                    .trimmingCharacters(in: .newlines)
                if excerptLine.hasPrefix("> 原文 ·") {
                    var end = NSMaxRange(excerptRange)
                    if end < nsSource.length {
                        let separatorRange = nsSource.lineRange(
                            for: NSRange(location: end, length: 0)
                        )
                        let separator = nsSource.substring(with: separatorRange)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if separator == ">" {
                            end = NSMaxRange(separatorRange)
                        }
                    }
                    results.append(NSRange(
                        location: NSMaxRange(headingLineRange),
                        length: end - NSMaxRange(headingLineRange)
                    ))
                    location = end
                    continue
                }
            }
            location = NSMaxRange(headingLineRange)
        }
        return results
    }

    /// 批注块标题里「批注」两个字的范围（按文档顺序）。
    /// 编辑器据此在标题后绘制平排圈号，编号即这里的顺序。
    static func annotationHeadingContentRanges(in source: String) -> [NSRange] {
        let nsSource = source as NSString
        var results: [NSRange] = []
        var location = 0
        while location < nsSource.length {
            let lineRange = nsSource.lineRange(
                for: NSRange(location: location, length: 0)
            )
            let line = nsSource.substring(with: lineRange)
                .trimmingCharacters(in: .newlines)
            if isHeading(line) {
                let contentRange = (line as NSString).range(of: "批注")
                if contentRange.location != NSNotFound {
                    results.append(NSRange(
                        location: lineRange.location + contentRange.location,
                        length: contentRange.length
                    ))
                }
            }
            location = NSMaxRange(lineRange)
        }
        return results
    }

    /// 光标所在位置的批注块范围：标题行 + 连续的「>」内容行，
    /// 并吞掉块前紧邻的空行，删除后不留空档。不在任何批注块内时返回 nil。
    static func annotationBlockRange(
        at location: Int,
        in source: String
    ) -> NSRange? {
        let nsSource = source as NSString
        guard nsSource.length > 0, location >= 0, location <= nsSource.length
        else { return nil }
        let clamped = min(location, nsSource.length - 1)

        func lineText(_ lineStart: Int) -> (range: NSRange, text: String) {
            let range = nsSource.lineRange(
                for: NSRange(location: lineStart, length: 0)
            )
            return (range, nsSource.substring(with: range))
        }
        func trimmed(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 从光标所在行向上找批注块标题行（跳过同块的「>」行）。
        var cursor = lineText(clamped).range.location
        var headingStart: Int?
        while cursor >= 0 {
            let line = lineText(cursor)
            if isHeading(line.text.trimmingCharacters(in: .newlines)) {
                headingStart = cursor
                break
            }
            guard trimmed(line.text).hasPrefix(">"), cursor > 0 else { break }
            cursor = lineText(cursor - 1).range.location
        }
        guard let blockStart = headingStart else { return nil }

        // 向下收集连续的「>」行（含换行）。
        var end = NSMaxRange(lineText(blockStart).range)
        var nextLineStart = end
        while nextLineStart < nsSource.length {
            let line = lineText(nextLineStart)
            guard trimmed(line.text).hasPrefix(">") else { break }
            end = NSMaxRange(line.range)
            nextLineStart = end
        }

        // 吞掉块前紧邻的空行。
        var start = blockStart
        if start > 0, nsSource.character(at: start - 1) == 10 {
            let previous = lineText(start - 1)
            if trimmed(previous.text).isEmpty {
                start = previous.range.location
            }
        }
        return NSRange(location: start, length: end - start)
    }

    /// 圈号数字，1–30 用 ①②…；超出后退化为普通括号数字。
    static func circledNumber(_ number: Int) -> String {
        let circled = Array("①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳㉑㉒㉓㉔㉕㉖㉗㉘㉙㉚")
        guard number >= 1, number <= circled.count else { return "(\(number))" }
        return String(circled[number - 1])
    }

    /// 阅读模式批注卡里的原文节选压到 30 字，超出加省略号，保留引号收尾。
    static func shortenedExcerpt(from contextLine: String) -> String {
        guard let open = contextLine.range(of: "「"),
              let close = contextLine.range(of: "」", options: .backwards),
              open.lowerBound < close.lowerBound else {
            return contextLine
        }
        let inner = contextLine[
            contextLine.index(after: open.lowerBound)..<close.lowerBound
        ]
        let limit = 30
        guard inner.count > limit else { return contextLine }
        return contextLine[..<contextLine.index(after: open.lowerBound)]
            + inner.prefix(limit) + "……"
            + contextLine[close.lowerBound...]
    }
}
