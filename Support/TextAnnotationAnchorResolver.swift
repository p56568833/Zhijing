import Foundation

enum TextAnnotationAnchorResolver {
    private static let contextLength = 80

    static func makeAnchor(
        selection: EditorTextSelection,
        in text: String
    ) -> TextAnnotationAnchor? {
        let source = text as NSString
        guard selection.range.length > 0,
              NSMaxRange(selection.range) <= source.length,
              source.substring(with: selection.range) == selection.text else {
            return nil
        }

        let prefixLocation = max(0, selection.range.location - contextLength)
        let prefixCandidate = NSRange(
            location: prefixLocation,
            length: selection.range.location - prefixLocation
        )
        let suffixEnd = min(
            source.length,
            NSMaxRange(selection.range) + contextLength
        )
        let suffixCandidate = NSRange(
            location: NSMaxRange(selection.range),
            length: suffixEnd - NSMaxRange(selection.range)
        )
        let prefixRange = source.rangeOfComposedCharacterSequences(
            for: prefixCandidate
        )
        let suffixRange = source.rangeOfComposedCharacterSequences(
            for: suffixCandidate
        )
        return TextAnnotationAnchor(
            selectedText: selection.text,
            utf16Location: selection.range.location,
            prefix: source.substring(with: prefixRange),
            suffix: source.substring(with: suffixRange)
        )
    }

    static func resolve(
        _ annotation: TextAnnotation,
        in text: String
    ) -> ResolvedTextAnnotation? {
        let source = text as NSString
        let anchor = annotation.anchor
        guard !anchor.selectedText.isEmpty else { return nil }
        let expected = NSRange(
            location: max(0, anchor.utf16Location),
            length: (anchor.selectedText as NSString).length
        )
        if NSMaxRange(expected) <= source.length,
           source.substring(with: expected) == anchor.selectedText {
            return ResolvedTextAnnotation(annotation: annotation, range: expected)
        }

        var candidates: [NSRange] = []
        var searchRange = NSRange(location: 0, length: source.length)
        while searchRange.length > 0 {
            let match = source.range(
                of: anchor.selectedText,
                options: [],
                range: searchRange
            )
            guard match.location != NSNotFound else { break }
            candidates.append(match)
            let nextLocation = NSMaxRange(match)
            guard nextLocation < source.length else { break }
            searchRange = NSRange(
                location: nextLocation,
                length: source.length - nextLocation
            )
        }
        guard !candidates.isEmpty else { return nil }

        let best = candidates.max { lhs, rhs in
            score(lhs, anchor: anchor, source: source) <
                score(rhs, anchor: anchor, source: source)
        }!
        return ResolvedTextAnnotation(annotation: annotation, range: best)
    }

    private static func score(
        _ range: NSRange,
        anchor: TextAnnotationAnchor,
        source: NSString
    ) -> Int {
        var value = -abs(range.location - anchor.utf16Location)
        if !anchor.prefix.isEmpty {
            let length = min((anchor.prefix as NSString).length, range.location)
            let candidate = source.substring(with: NSRange(
                location: range.location - length,
                length: length
            ))
            if anchor.prefix.hasSuffix(candidate) {
                value += 10_000 + length
            }
        }
        if !anchor.suffix.isEmpty {
            let available = source.length - NSMaxRange(range)
            let length = min((anchor.suffix as NSString).length, available)
            let candidate = source.substring(with: NSRange(
                location: NSMaxRange(range),
                length: length
            ))
            if anchor.suffix.hasPrefix(candidate) {
                value += 10_000 + length
            }
        }
        return value
    }
}
