import Foundation
import Testing
@testable import Zhijing

@Test func movedReordersElementBetweenPositions() {
    let paths = ["a", "b", "c", "d"]
    #expect(
        DocumentOrdering.moved(paths, fromIndex: 0, toIndex: 2) == ["b", "c", "a", "d"]
    )
    #expect(
        DocumentOrdering.moved(paths, fromIndex: 3, toIndex: 0) == ["d", "a", "b", "c"]
    )
}

@Test func movedClampsOutOfRangeTargets() {
    let paths = ["a", "b", "c"]
    #expect(
        DocumentOrdering.moved(paths, fromIndex: 1, toIndex: 99) == ["a", "c", "b"]
    )
    #expect(
        DocumentOrdering.moved(paths, fromIndex: 1, toIndex: -5) == ["b", "a", "c"]
    )
    #expect(DocumentOrdering.moved(paths, fromIndex: 1, toIndex: 1) == paths)
    #expect(DocumentOrdering.moved([String](), fromIndex: 0, toIndex: 0) == [])
}

@Test func applyingManualOrderPutsKnownPathsFirstAndKeepsRest() {
    let result = DocumentOrdering.applyingManualOrder(
        ["丙", "甲"],
        to: ["甲", "乙", "丙", "丁"]
    )
    #expect(result == ["丙", "甲", "乙", "丁"])
}

@Test func mergedManualOrderKeepsUnseenDocumentsInPreviousOrder() {
    let result = DocumentOrdering.mergedManualOrder(
        visible: ["新1", "新2"],
        previous: ["旧1", "新2", "旧2"],
        universe: ["新1", "新2", "旧1", "旧2", "旧3"]
    )
    #expect(result == ["新1", "新2", "旧1", "旧2", "旧3"])
}
