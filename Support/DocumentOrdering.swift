import Foundation

/// 文库列表与标签页的手动排序逻辑（纯函数，便于测试）。
enum DocumentOrdering {
    /// 把 fromIndex 位置的元素移动到 toIndex，越界时收敛到合法范围。
    static func moved<T>(
        _ array: [T],
        fromIndex: Int,
        toIndex: Int
    ) -> [T] {
        guard !array.isEmpty,
              array.indices.contains(fromIndex) else { return array }
        let target = min(max(toIndex, 0), array.count - 1)
        guard target != fromIndex else { return array }
        var result = array
        let element = result.remove(at: fromIndex)
        result.insert(element, at: target)
        return result
    }

    /// 文库手动排序：按手动顺序表排列给定的文稿路径；
    /// 表中没有的路径保持原有相对顺序排在后面。
    static func applyingManualOrder(
        _ manualOrder: [String],
        to paths: [String]
    ) -> [String] {
        let pathSet = Set(paths)
        let ordered = manualOrder.filter { pathSet.contains($0) }
        let leftovers = paths.filter { !manualOrder.contains($0) }
        return ordered + leftovers
    }

    /// 拖拽排序后，把"可见列表的新顺序"合并回全局手动顺序表：
    /// 其余文稿保持之前的相对顺序，接在可见部分之后。
    static func mergedManualOrder(
        visible: [String],
        previous: [String],
        universe: [String]
    ) -> [String] {
        var result = visible
        var seen = Set(visible)
        for path in previous where !seen.contains(path) {
            result.append(path)
            seen.insert(path)
        }
        for path in universe where !seen.contains(path) {
            result.append(path)
            seen.insert(path)
        }
        return result
    }
}
