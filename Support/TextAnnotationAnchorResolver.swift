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
           source.substring(with: expected) == anchor.selectedText,
           contextMatches(expected, anchor: anchor, source: source) {
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

        let ranked = candidates.map { range in
            (range: range, score: score(range, anchor: anchor, source: source))
        }.sorted {
            if $0.score == $1.score {
                return $0.range.location < $1.range.location
            }
            return $0.score > $1.score
        }
        guard let best = ranked.first else { return nil }
        if ranked.count > 1, ranked[1].score == best.score {
            return nil
        }
        return ResolvedTextAnnotation(annotation: annotation, range: best.range)
    }

    static func reanchor(
        _ annotation: TextAnnotation,
        from oldText: String,
        to newText: String,
        mutation: EditorTextMutation? = nil
    ) -> TextAnnotation {
        guard oldText != newText,
              let oldResolved = resolve(annotation, in: oldText),
              let edit = verifiedEdit(
                  mutation,
                  oldText: oldText,
                  newText: newText
              ) ?? inferredEdit(from: oldText, to: newText),
              let newRange = transformed(
                  oldResolved.range,
                  through: edit,
                  newText: newText
              ),
              newRange.length > 0 else {
            return annotation
        }

        let source = newText as NSString
        let selection = EditorTextSelection(
            documentID: "",
            range: newRange,
            text: source.substring(with: newRange)
        )
        guard let anchor = makeAnchor(selection: selection, in: newText) else {
            return annotation
        }
        var updated = annotation
        updated.anchor = anchor
        updated.modifiedAt = .now
        return updated
    }

    private static func verifiedEdit(
        _ mutation: EditorTextMutation?,
        oldText: String,
        newText: String
    ) -> EditorTextMutation? {
        guard let mutation else { return nil }
        let source = oldText as NSString
        guard mutation.range.location >= 0,
              NSMaxRange(mutation.range) <= source.length,
              source.replacingCharacters(
                  in: mutation.range,
                  with: mutation.replacementText
              ) == newText else { return nil }
        return mutation
    }

    private static func inferredEdit(
        from oldText: String,
        to newText: String
    ) -> EditorTextMutation? {
        let oldSource = oldText as NSString
        let newSource = newText as NSString
        var prefixLength = 0
        let sharedLength = min(oldSource.length, newSource.length)
        while prefixLength < sharedLength,
              oldSource.character(at: prefixLength) == newSource.character(at: prefixLength) {
            prefixLength += 1
        }

        var suffixLength = 0
        while suffixLength < oldSource.length - prefixLength,
              suffixLength < newSource.length - prefixLength,
              oldSource.character(at: oldSource.length - suffixLength - 1) ==
                newSource.character(at: newSource.length - suffixLength - 1) {
            suffixLength += 1
        }

        let replacementRange = NSRange(
            location: prefixLength,
            length: newSource.length - prefixLength - suffixLength
        )
        return EditorTextMutation(
            range: NSRange(
                location: prefixLength,
                length: oldSource.length - prefixLength - suffixLength
            ),
            replacementText: newSource.substring(with: replacementRange)
        )
    }

    private static func transformed(
        _ range: NSRange,
        through edit: EditorTextMutation,
        newText: String
    ) -> NSRange? {
        let editStart = edit.range.location
        let editEnd = NSMaxRange(edit.range)
        let replacementLength = (edit.replacementText as NSString).length
        let newEditEnd = editStart + replacementLength
        let delta = replacementLength - edit.range.length
        let rangeStart = range.location
        let rangeEnd = NSMaxRange(range)

        let transformedRange: NSRange
        if rangeEnd <= editStart {
            transformedRange = range
        } else if rangeStart >= editEnd {
            transformedRange = NSRange(
                location: max(0, rangeStart + delta),
                length: range.length
            )
        } else {
            let newStart = rangeStart < editStart ? rangeStart : editStart
            let newEnd = rangeEnd > editEnd ? rangeEnd + delta : newEditEnd
            transformedRange = NSRange(
                location: max(0, newStart),
                length: max(0, newEnd - newStart)
            )
        }

        let sourceLength = (newText as NSString).length
        guard transformedRange.location <= sourceLength,
              NSMaxRange(transformedRange) <= sourceLength else { return nil }
        return transformedRange
    }

    private static func contextMatches(
        _ range: NSRange,
        anchor: TextAnnotationAnchor,
        source: NSString
    ) -> Bool {
        var compared = false
        if !anchor.prefix.isEmpty, range.location > 0 {
            compared = true
            let length = min((anchor.prefix as NSString).length, range.location)
            let candidate = source.substring(with: NSRange(
                location: range.location - length,
                length: length
            ))
            if !anchor.prefix.hasSuffix(candidate) { return false }
        }
        if !anchor.suffix.isEmpty, NSMaxRange(range) < source.length {
            compared = true
            let available = source.length - NSMaxRange(range)
            let length = min((anchor.suffix as NSString).length, available)
            let candidate = source.substring(with: NSRange(
                location: NSMaxRange(range),
                length: length
            ))
            if !anchor.suffix.hasPrefix(candidate) { return false }
        }
        return compared || source.length == range.length
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
