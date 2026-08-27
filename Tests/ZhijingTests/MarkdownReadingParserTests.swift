import AppKit
import Testing
@testable import Zhijing

@Test func parsesPipedTableIntoHeaderAndRows() {
    let blocks = MarkdownReadingParser.parse(
        """
        | 名称 | 数量 |
        | --- | ---: |
        | 苹果 | 3 |
        | 香蕉 | 12 |
        """
    )

    let table = blocks.compactMap { block -> ([String], [[String]])? in
        guard case let .table(header, rows) = block.kind else { return nil }
        return (header, rows)
    }
    #expect(table.count == 1)
    #expect(table.first?.0 == ["名称", "数量"])
    #expect(table.first?.1 == [["苹果", "3"], ["香蕉", "12"]])
}

@Test func plainPipesWithoutSeparatorAreNotTables() {
    let blocks = MarkdownReadingParser.parse("| 只有 | 一行 |")
    #expect(blocks.allSatisfy { block in
        if case .table = block.kind { return false }
        return true
    })
}

@Test func parsesTaskListWithSourceLineNumbers() {
    let source = """
    ## 今日
    - [ ] 写周报
    - [x] 交房租
    """
    let blocks = MarkdownReadingParser.parse(source)

    let tasks = blocks.compactMap { block -> (Bool, Int, String)? in
        guard case let .taskList(indentation, isChecked) = block.kind else {
            return nil
        }
        return (isChecked, indentation, block.content)
    }

    #expect(tasks.count == 2)
    #expect(tasks[0] == (false, 0, "写周报"))
    #expect(tasks[1] == (true, 0, "交房租"))

    let uncheckedLine = blocks.first {
        if case .taskList = $0.kind { return true }
        return false
    }?.sourceLine
    #expect(uncheckedLine == 2)
}

@Test func parsesStandaloneImageLine() {
    let blocks = MarkdownReadingParser.parse("前文\n\n![截图](assets/shot.png)\n\n后文")
    #expect(blocks.contains { block in
        if case .image = block.kind { return true }
        return false
    })
}

@Test func taskListToggleSwitchesCheckboxMarker() {
    #expect(DocumentTaskList.toggled("- [ ] 写周报") == "- [x] 写周报")
    #expect(DocumentTaskList.toggled("- [x] 写周报") == "- [ ] 写周报")
    #expect(DocumentTaskList.toggled("- [X] 写周报") == "- [ ] 写周报")
    #expect(DocumentTaskList.toggled("- 普通条目") == nil)
    #expect(DocumentTaskList.toggled("正文没有复选框") == nil)
}

@Test func readingRendererAppliesStrikethrough() {
    let rendered = MarkdownReadingAttributedRenderer.render("~~旧结论~~ 保留")
    let text = rendered.string as NSString
    let range = text.range(of: "旧结论")
    #expect(range.location != NSNotFound)
    let style = rendered.attribute(
        .strikethroughStyle,
        at: range.location,
        effectiveRange: nil
    ) as? Int
    #expect(style == NSUnderlineStyle.single.rawValue)
}

@MainActor
@Test func appStoreTogglesTaskCheckboxOnSelectedDocumentLine() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "ZhijingTaskToggle-\(UUID().uuidString)", directoryHint: .isDirectory)
    let support = root.appending(path: "Support", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let documentURL = root.appending(path: "任务.md")
    try "- [ ] 第一项\n- [ ] 第二项".write(to: documentURL, atomically: true, encoding: .utf8)

    let suiteName = "ZhijingTaskToggleTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = AppStore(
        defaults: defaults,
        knowledgeBase: KnowledgeBaseService(supportDirectoryOverride: support)
    )
    store.libraryURL = root
    await store.refreshLibrary(selecting: "任务.md")
    #expect(store.editorText.contains("- [ ] 第一项"))

    store.toggleTaskCheckbox(atLine: 2)
    #expect(store.editorText == "- [ ] 第一项\n- [x] 第二项")

    #expect(store.saveNow())
    let text = try String(contentsOf: documentURL, encoding: .utf8)
    #expect(text == "- [ ] 第一项\n- [x] 第二项")
}
