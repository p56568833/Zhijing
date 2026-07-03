import Foundation

struct LineDiff {
    let removedOffsets: Set<Int>
    let insertedOffsets: Set<Int>

    init(original: String, replacement: String) {
        let oldLines = original.components(separatedBy: .newlines)
        let newLines = replacement.components(separatedBy: .newlines)
        let difference = newLines.difference(from: oldLines)
        var removed: Set<Int> = []
        var inserted: Set<Int> = []
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        removedOffsets = removed
        insertedOffsets = inserted
    }
}
