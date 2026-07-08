import Foundation

enum DocumentFindMatcher {
    static func matches(
        in source: String,
        options: DocumentFindOptions
    ) -> [NSRange] {
        let query = options.trimmedQuery
        guard !query.isEmpty else { return [] }

        let nsSource = source as NSString
        let searchOptions: NSString.CompareOptions = options.matchCase
            ? []
            : [.caseInsensitive, .diacriticInsensitive]
        var result: [NSRange] = []
        var searchRange = NSRange(location: 0, length: nsSource.length)

        while searchRange.length > 0 {
            let match = nsSource.range(
                of: query,
                options: searchOptions,
                range: searchRange
            )
            guard match.location != NSNotFound, match.length > 0 else { break }

            if !options.wholeWord || isWholeWordMatch(match, in: nsSource) {
                result.append(match)
            }

            let nextLocation = match.location + max(match.length, 1)
            guard nextLocation <= nsSource.length else { break }
            searchRange = NSRange(
                location: nextLocation,
                length: nsSource.length - nextLocation
            )
        }

        return result
    }

    private static func isWholeWordMatch(
        _ range: NSRange,
        in source: NSString
    ) -> Bool {
        guard range.length > 0 else { return false }
        let matched = source.substring(with: range)
        guard matched.unicodeScalars.contains(where: isWordScalar) else {
            return true
        }

        let before = scalar(before: range.location, in: source)
        let after = scalar(at: NSMaxRange(range), in: source)
        let startsAtBoundary = before.map { !isWordScalar($0) } ?? true
        let endsAtBoundary = after.map { !isWordScalar($0) } ?? true
        return startsAtBoundary && endsAtBoundary
    }

    private static func scalar(before location: Int, in source: NSString) -> UnicodeScalar? {
        guard location > 0 else { return nil }
        return scalar(at: location - 1, in: source)
    }

    private static func scalar(at location: Int, in source: NSString) -> UnicodeScalar? {
        guard location >= 0, location < source.length else { return nil }
        return UnicodeScalar(source.character(at: location))
    }

    private static func isWordScalar(_ scalar: UnicodeScalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }
}
