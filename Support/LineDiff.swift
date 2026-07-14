import Foundation

struct LineDiffHunk: Identifiable, Hashable {
    let id: Int
    let originalRange: Range<Int>
    let replacementRange: Range<Int>
    let originalLines: [String]
    let replacementLines: [String]

    var removedCount: Int { originalLines.count }
    var insertedCount: Int { replacementLines.count }
}

struct LineDiff {
    let originalLines: [String]
    let replacementLines: [String]
    let removedOffsets: Set<Int>
    let insertedOffsets: Set<Int>
    let hunks: [LineDiffHunk]

    init(original: String, replacement: String) {
        let oldLines = original.components(separatedBy: .newlines)
        let newLines = replacement.components(separatedBy: .newlines)
        let difference = newLines.difference(from: oldLines)
        var removed: Set<Int> = []
        var inserted: Set<Int> = []
        for change in difference {
            switch change {
            case let .remove(offset, _, _):
                removed.insert(offset)
            case let .insert(offset, _, _):
                inserted.insert(offset)
            }
        }

        originalLines = oldLines
        replacementLines = newLines
        removedOffsets = removed
        insertedOffsets = inserted
        hunks = Self.makeHunks(
            originalLines: oldLines,
            replacementLines: newLines,
            removedOffsets: removed,
            insertedOffsets: inserted
        )
    }

    func applying(acceptedHunkIDs: Set<LineDiffHunk.ID>) -> String {
        var result: [String] = []
        var originalCursor = 0
        for hunk in hunks {
            if originalCursor < hunk.originalRange.lowerBound {
                result.append(contentsOf: originalLines[
                    originalCursor..<hunk.originalRange.lowerBound
                ])
            }
            if acceptedHunkIDs.contains(hunk.id) {
                result.append(contentsOf: hunk.replacementLines)
            } else {
                result.append(contentsOf: hunk.originalLines)
            }
            originalCursor = hunk.originalRange.upperBound
        }
        if originalCursor < originalLines.count {
            result.append(contentsOf: originalLines[originalCursor...])
        }
        return result.joined(separator: "\n")
    }

    func resolving(
        hunkID: LineDiffHunk.ID,
        accepted: Bool
    ) -> LineDiffResolution? {
        guard let hunk = hunks.first(where: { $0.id == hunkID }) else {
            return nil
        }
        let remainingHunkIDs = Set(hunks.map(\.id)).subtracting([hunkID])
        let settledText = applying(
            acceptedHunkIDs: accepted ? [hunkID] : []
        )
        let replacementHunkIDs = remainingHunkIDs.union(
            accepted ? [hunkID] : []
        )
        return LineDiffResolution(
            settledText: settledText,
            remainingReplacement: remainingHunkIDs.isEmpty
                ? nil
                : applying(acceptedHunkIDs: replacementHunkIDs),
            settledLine: hunk.originalRange.lowerBound + 1
        )
    }

    private static func makeHunks(
        originalLines: [String],
        replacementLines: [String],
        removedOffsets: Set<Int>,
        insertedOffsets: Set<Int>
    ) -> [LineDiffHunk] {
        var result: [LineDiffHunk] = []
        var oldIndex = 0
        var newIndex = 0

        while oldIndex < originalLines.count || newIndex < replacementLines.count {
            let isUnchanged = oldIndex < originalLines.count &&
                newIndex < replacementLines.count &&
                !removedOffsets.contains(oldIndex) &&
                !insertedOffsets.contains(newIndex) &&
                originalLines[oldIndex] == replacementLines[newIndex]
            if isUnchanged {
                oldIndex += 1
                newIndex += 1
                continue
            }

            let oldStart = oldIndex
            let newStart = newIndex
            while oldIndex < originalLines.count,
                  removedOffsets.contains(oldIndex) {
                oldIndex += 1
            }
            while newIndex < replacementLines.count,
                  insertedOffsets.contains(newIndex) {
                newIndex += 1
            }

            // CollectionDifference marks every mismatch as an insertion,
            // removal, or both. This fallback guarantees forward progress if
            // a future standard-library implementation represents it differently.
            if oldStart == oldIndex, newStart == newIndex {
                if oldIndex < originalLines.count { oldIndex += 1 }
                if newIndex < replacementLines.count { newIndex += 1 }
            }

            result.append(LineDiffHunk(
                id: result.count,
                originalRange: oldStart..<oldIndex,
                replacementRange: newStart..<newIndex,
                originalLines: Array(originalLines[oldStart..<oldIndex]),
                replacementLines: Array(replacementLines[newStart..<newIndex])
            ))
        }
        return result
    }
}

struct LineDiffResolution: Equatable {
    let settledText: String
    let remainingReplacement: String?
    let settledLine: Int
}

enum InlineDiffLineKind: Equatable {
    case unchanged
    case removed
    case inserted
}

struct InlineDiffDecoration: Equatable {
    let range: NSRange
    let kind: InlineDiffLineKind
    let hunkID: LineDiffHunk.ID
}

struct InlineDiffControlAnchor: Equatable {
    let range: NSRange
    let hunkID: LineDiffHunk.ID
}

struct InlineDiffPresentation {
    let text: String
    let decorations: [InlineDiffDecoration]
    let controlAnchors: [InlineDiffControlAnchor]

    var firstChangeRange: NSRange? {
        decorations.first?.range
    }

    init(diff: LineDiff) {
        typealias Row = (
            text: String,
            kind: InlineDiffLineKind,
            hunkID: LineDiffHunk.ID?,
            controlHunkID: LineDiffHunk.ID?
        )
        var rows: [Row] = []
        var originalCursor = 0

        for hunk in diff.hunks {
            if originalCursor < hunk.originalRange.lowerBound {
                rows.append(contentsOf: diff.originalLines[
                    originalCursor..<hunk.originalRange.lowerBound
                ].map { ($0, .unchanged, nil, nil) })
            }
            rows.append(contentsOf: hunk.originalLines.map {
                ($0, .removed, hunk.id, nil)
            })
            rows.append(contentsOf: hunk.replacementLines.map {
                ($0, .inserted, hunk.id, nil)
            })
            rows.append((" ", .unchanged, nil, hunk.id))
            originalCursor = hunk.originalRange.upperBound
        }

        if originalCursor < diff.originalLines.count {
            rows.append(contentsOf: diff.originalLines[originalCursor...].map {
                ($0, .unchanged, nil, nil)
            })
        }

        var renderedText = ""
        var renderedDecorations: [InlineDiffDecoration] = []
        var renderedControlAnchors: [InlineDiffControlAnchor] = []
        var utf16Location = 0

        for (index, row) in rows.enumerated() {
            if index > 0 {
                renderedText.append("\n")
                utf16Location += 1
            }
            let length = row.text.utf16.count
            if row.kind != .unchanged, let hunkID = row.hunkID {
                renderedDecorations.append(InlineDiffDecoration(
                    range: NSRange(location: utf16Location, length: length),
                    kind: row.kind,
                    hunkID: hunkID
                ))
            }
            if let hunkID = row.controlHunkID {
                renderedControlAnchors.append(InlineDiffControlAnchor(
                    range: NSRange(location: utf16Location, length: length),
                    hunkID: hunkID
                ))
            }
            renderedText.append(row.text)
            utf16Location += length
        }

        text = renderedText
        decorations = renderedDecorations
        controlAnchors = renderedControlAnchors
    }
}
