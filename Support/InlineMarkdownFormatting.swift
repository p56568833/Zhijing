import Foundation

struct InlineWrapMutation: Equatable {
    let range: NSRange
    let replacementText: String
    let selectionRange: NSRange
}

/// 加粗、斜体、删除线的标准 Markdown 包裹语法切换。
enum InlineMarkdownFormatting {
    enum WrapStyle: String, CaseIterable, Sendable {
        case bold = "**"
        case italic = "*"
        case strikethrough = "~~"

        var title: String {
            switch self {
            case .bold: "加粗"
            case .italic: "斜体"
            case .strikethrough: "删除线"
            }
        }
    }

    static func mutation(
        in source: String,
        selection: NSRange,
        style: WrapStyle
    ) -> InlineWrapMutation? {
        let nsSource = source as NSString
        let marker = style.rawValue
        let markerLength = (marker as NSString).length
        guard selection.length > 0,
              selection.location >= 0,
              NSMaxRange(selection) <= nsSource.length else { return nil }

        let selectedText = nsSource.substring(with: selection)
        // 跨行文本不包裹：标记语法在行内有明确语义，跨行应用易产生歧义。
        guard !selectedText.contains("\n"),
              !selectedText.contains("\r"),
              !selectedText.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }

        // 选中内容两侧紧邻同样的标记 → 视为已应用，执行取消。
        let prefixRange = NSRange(
            location: selection.location - markerLength,
            length: markerLength
        )
        let suffixRange = NSRange(
            location: NSMaxRange(selection),
            length: markerLength
        )
        if prefixRange.location >= 0,
           nsSource.substring(with: prefixRange) == marker,
           NSMaxRange(suffixRange) <= nsSource.length,
           nsSource.substring(with: suffixRange) == marker {
            let fullRange = NSRange(
                location: prefixRange.location,
                length: selection.length + markerLength * 2
            )
            return InlineWrapMutation(
                range: fullRange,
                replacementText: selectedText,
                selectionRange: NSRange(
                    location: selection.location - markerLength,
                    length: selection.length
                )
            )
        }

        let replacement = marker + selectedText + marker
        return InlineWrapMutation(
            range: selection,
            replacementText: replacement,
            selectionRange: NSRange(
                location: selection.location + markerLength,
                length: selection.length
            )
        )
    }
}
