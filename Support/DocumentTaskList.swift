import Foundation

/// 阅读模式下点击任务复选框时，在源文本行上切换 `[ ]` / `[x]` 标记。
enum DocumentTaskList {
    static func toggled(_ line: String) -> String? {
        if let range = line.range(of: "[ ]") {
            var updated = line
            updated.replaceSubrange(range, with: "[x]")
            return updated
        }
        if let range = line.range(of: "[x]") ?? line.range(of: "[X]") {
            var updated = line
            updated.replaceSubrange(range, with: "[ ]")
            return updated
        }
        return nil
    }
}
