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
