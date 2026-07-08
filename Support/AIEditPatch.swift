import Foundation

struct AITextEdit: Codable, Hashable, Sendable {
    let oldText: String
    let newText: String
    let scope: String?
    let reason: String?

    init(
        oldText: String,
        newText: String,
        scope: String? = nil,
        reason: String? = nil
    ) {
        self.oldText = oldText
        self.newText = newText
        self.scope = scope
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case oldText = "old_text"
        case newText = "new_text"
        case scope
        case reason
    }
}

struct AIEditPatch: Codable, Hashable, Sendable {
    let edits: [AITextEdit]
}

struct ResolvedAITextEdit: Sendable {
    let range: NSRange
    let replacement: String
    let scope: String?
    let reason: String?
}

struct AIEditPatchApplication: Sendable {
    let replacement: String
    let edits: [ResolvedAITextEdit]
}

enum AIEditPatchProcessor {
    static func apply(response: String, to original: String) throws -> String {
        try applyDetailed(response: response, to: original).replacement
    }

    static func applyDetailed(
        response: String,
        to original: String
    ) throws -> AIEditPatchApplication {
        try applyDetailed(patch: decode(response), to: original)
    }

    static func extractFromChat(
        _ response: String,
        original: String
    ) throws -> (display: String, replacement: String?) {
        let marker = "```edit-patch"
        guard let markerRange = response.range(of: marker) else {
            return legacyFullDocumentEdit(from: response)
        }
        guard let contentStart = response[markerRange.upperBound...]
            .firstIndex(of: "\n") else {
            throw patchError("AI 返回的局部修改格式不完整。")
        }
        let content = response[response.index(after: contentStart)...]
        guard let endRange = content.range(of: "\n```") else {
            throw patchError("AI 返回的局部修改缺少结束标记。")
        }

        let json = String(content[..<endRange.lowerBound])
        let replacement = try apply(response: json, to: original)
        let suffix = content[endRange.upperBound...]
        let display = (
            String(response[..<markerRange.lowerBound]) + String(suffix)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            display.isEmpty ? "已生成局部修改，等待你确认。" : display,
            replacement
        )
    }

    static func apply(patch: AIEditPatch, to original: String) throws -> String {
        try applyDetailed(patch: patch, to: original).replacement
    }

    static func applyDetailed(
        patch: AIEditPatch,
        to original: String
    ) throws -> AIEditPatchApplication {
        let meaningfulEdits = patch.edits.filter { $0.oldText != $0.newText }
        guard !meaningfulEdits.isEmpty else {
            throw patchError("AI 没有返回实际修改。")
        }

        let source = original as NSString
        var resolved: [ResolvedAITextEdit] = []
        for edit in meaningfulEdits {
            guard !edit.oldText.isEmpty else {
                throw patchError("局部修改缺少原文定位片段。")
            }
            let matches = ranges(of: edit.oldText, in: source)
            guard !matches.isEmpty else {
                throw patchError("AI 返回的原文片段无法在当前文稿中找到，请重新生成。")
            }
            guard matches.count == 1, let match = matches.first else {
                throw patchError("AI 返回的原文片段在文稿中出现多次，无法安全定位，请重新生成。")
            }
            resolved.append(ResolvedAITextEdit(
                range: match,
                replacement: edit.newText,
                scope: edit.scope,
                reason: edit.reason
            ))
        }

        let sorted = resolved.sorted { $0.range.location < $1.range.location }
        for pair in zip(sorted, sorted.dropFirst()) {
            guard NSMaxRange(pair.0.range) <= pair.1.range.location else {
                throw patchError("AI 返回的修改片段彼此重叠，无法安全应用。")
            }
        }

        let result = NSMutableString(string: original)
        for edit in sorted.reversed() {
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return AIEditPatchApplication(
            replacement: result as String,
            edits: sorted
        )
    }

    private static func decode(_ response: String) throws -> AIEditPatch {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}"),
           firstBrace <= lastBrace {
            json = String(trimmed[firstBrace...lastBrace])
        } else {
            throw patchError("AI 没有返回可识别的局部修改 JSON。")
        }

        do {
            return try JSONDecoder().decode(AIEditPatch.self, from: Data(json.utf8))
        } catch {
            throw patchError("AI 返回的局部修改 JSON 无法解析，请重新生成。")
        }
    }

    private static func ranges(
        of needle: String,
        in source: NSString
    ) -> [NSRange] {
        let fullRange = NSRange(location: 0, length: source.length)
        var matches: [NSRange] = []
        var searchRange = fullRange
        while searchRange.length > 0 {
            let match = source.range(
                of: needle,
                options: [.literal],
                range: searchRange
            )
            guard match.location != NSNotFound else { break }
            matches.append(match)
            let nextLocation = NSMaxRange(match)
            searchRange = NSRange(
                location: nextLocation,
                length: fullRange.length - nextLocation
            )
        }
        return matches
    }

    private static func legacyFullDocumentEdit(
        from response: String
    ) -> (display: String, replacement: String?) {
        let marker = "```edit\n"
        let endMarker = "\n```"
        guard let start = response.range(of: marker) else {
            return (response, nil)
        }
        let after = response[start.upperBound...]
        guard let end = after.range(of: endMarker) else {
            return (response, nil)
        }
        let replacement = String(after[..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = after[end.upperBound...]
        let display = (
            String(response[..<start.lowerBound]) + String(suffix)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            display.isEmpty ? "已生成修改，等待你确认。" : display,
            replacement
        )
    }

    private static func patchError(_ message: String) -> NSError {
        NSError(
            domain: "AIEditPatch",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
