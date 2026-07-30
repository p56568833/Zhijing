import Foundation

enum AIContextBuilder {
    private static let fullDocumentLimit = 12_000

    static func answerContext(
        question: String,
        document: NoteDocument,
        text: String,
        selection: EditorTextSelection?,
        annotations: [TextAnnotation]
    ) -> String {
        let annotationText = annotationContext(
            annotations: annotations,
            in: text
        )
        guard text.utf16.count > fullDocumentLimit else {
            return annotationText.isEmpty
                ? text
                : "\(text)\n\n---\n\n\(annotationText)"
        }

        let nsText = text as NSString
        var sections: [String] = []
        sections.append("文稿：\(document.relativePath)")
        sections.append("[开头]\n\(String(text.prefix(2_200)))")

        if let selection, !selection.isEmpty {
            sections.append("[当前选区]\n\(selection.text)")
        }

        let queryTerms = Set(SearchTokenization.tokenize(question))
        let lines = text.components(separatedBy: .newlines)
        let scoredLines = lines.enumerated().compactMap { index, line -> (Int, Double)? in
            let terms = Set(SearchTokenization.tokenize(line))
            let score = Double(queryTerms.intersection(terms).count)
            return score > 0 ? (index, score) : nil
        }
        .sorted {
            if $0.1 == $1.1 { return $0.0 < $1.0 }
            return $0.1 > $1.1
        }
        .prefix(8)

        var usedRanges: [Range<Int>] = []
        for (index, _) in scoredLines {
            let range = max(0, index - 2)..<min(lines.count, index + 3)
            guard !usedRanges.contains(where: { rangesOverlap($0, range) }) else {
                continue
            }
            usedRanges.append(range)
            let snippet = lines[range].joined(separator: "\n")
            sections.append("[相关片段 · 第 \(range.lowerBound + 1) 行]\n\(snippet)")
        }

        let tailStart = max(0, nsText.length - 1_600)
        let tailRange = nsText.rangeOfComposedCharacterSequences(
            for: NSRange(location: tailStart, length: nsText.length - tailStart)
        )
        sections.append("[结尾]\n\(nsText.substring(with: tailRange))")

        if !annotationText.isEmpty {
            sections.append(annotationText)
        }

        return sections.joined(separator: "\n\n---\n\n")
    }

    static func annotationContext(
        annotations: [TextAnnotation],
        in text: String
    ) -> String {
        guard !annotations.isEmpty else { return "" }
        let items = annotations.prefix(30).enumerated().map { index, annotation in
            let resolved = TextAnnotationAnchorResolver.resolve(annotation, in: text)
            let status = resolved == nil ? "（原文已修改或删除，位置待确认）" : ""
            return """
            [用户批注\(index + 1)]
            对应原文\(status)：\(annotation.anchor.selectedText)
            批注：\(annotation.text)
            """
        }.joined(separator: "\n\n")
        return """
        [用户批注]
        以下内容是用户附在原文上的持久批注，代表用户的判断、问题或修改意图，不是文稿中的事实或引用来源。

        \(items)
        """
    }

    static func contains(_ container: NSRange, range: NSRange) -> Bool {
        range.location >= container.location &&
            NSMaxRange(range) <= NSMaxRange(container)
    }

    static func lineRange(
        for range: NSRange,
        in text: String
    ) -> Range<Int> {
        let source = text as NSString
        let start = min(range.location, source.length)
        let end = min(max(start, NSMaxRange(range) - 1), max(0, source.length - 1))
        let startLine = source.substring(to: start)
            .reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        let endLine = source.substring(to: min(source.length, end + 1))
            .reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        return startLine..<max(startLine + 1, endLine + 1)
    }

    static func surroundingContext(
        in text: String,
        selection: NSRange,
        padding: Int = 2_400
    ) -> String {
        let source = text as NSString
        let lower = max(0, selection.location - padding)
        let upper = min(source.length, NSMaxRange(selection) + padding)
        let safeRange = source.rangeOfComposedCharacterSequences(
            for: NSRange(location: lower, length: upper - lower)
        )
        return source.substring(with: safeRange)
    }

    private static func rangesOverlap(
        _ lhs: Range<Int>,
        _ rhs: Range<Int>
    ) -> Bool {
        lhs.lowerBound < rhs.upperBound && rhs.lowerBound < lhs.upperBound
    }
}
