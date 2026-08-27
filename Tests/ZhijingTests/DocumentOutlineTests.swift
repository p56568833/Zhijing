import Testing
@testable import Zhijing

@Test func documentOutlineFindsMarkdownHeadingsAndSourceLines() {
    let markdown = """
    # 标题

    开场
    ## 第一部分
    ### **细节**

    结尾
    ===
    """

    #expect(DocumentOutlineParser.parse(markdown) == [
        DocumentOutlineItem(title: "标题", level: 1, line: 1),
        DocumentOutlineItem(title: "第一部分", level: 2, line: 4),
        DocumentOutlineItem(title: "细节", level: 3, line: 5),
        DocumentOutlineItem(title: "结尾", level: 1, line: 7),
    ])
}

@Test func documentOutlineIgnoresHeadingsInsideCodeFences() {
    let markdown = """
    ## 正文
    ```markdown
    # 代码中的标题
    ```
    ### 继续正文
    """

    #expect(DocumentOutlineParser.parse(markdown) == [
        DocumentOutlineItem(title: "正文", level: 2, line: 1),
        DocumentOutlineItem(title: "继续正文", level: 3, line: 5),
    ])
}

@Test func documentOutlineDoesNotTreatHorizontalRulesAsHeadingsWithoutATitle() {
    let markdown = """
    # 开头

    ---

    ## 结尾
    """

    #expect(DocumentOutlineParser.parse(markdown).map(\.title) == ["开头", "结尾"])
}
