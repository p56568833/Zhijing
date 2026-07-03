import SwiftUI

struct MarkdownReadingView: View {
    let text: String

    private var blocks: [MarkdownReadingBlock] {
        MarkdownReadingParser.parse(text)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(blocks) { block in
                    blockView(block)
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 46)
            .padding(.vertical, 38)
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownReadingBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(MarkdownInlineRenderer.render(block.content))
                .font(headingFont(level))
                .foregroundStyle(.blue)
                .padding(.top, level == 1 ? 4 : 14)
                .padding(.bottom, level == 1 ? 18 : 9)

        case .paragraph:
            Text(MarkdownInlineRenderer.render(block.content))
                .font(.system(size: 16))
                .lineSpacing(6)
                .foregroundStyle(.primary)
                .padding(.bottom, 14)

        case .quote:
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.green.opacity(0.72))
                    .frame(width: 3)
                Text(MarkdownInlineRenderer.render(block.content))
                    .font(.system(size: 16).italic())
                    .lineSpacing(5)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(.green.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 14)

        case .unorderedList(let indentation):
            HStack(alignment: .firstTextBaseline, spacing: 11) {
                Text("•")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.orange)
                Text(MarkdownInlineRenderer.render(block.content))
                    .font(.system(size: 16))
                    .lineSpacing(5)
                    .foregroundStyle(.primary)
            }
            .padding(.leading, CGFloat(indentation) * 18)
            .padding(.bottom, 7)

        case .orderedList(let marker, let indentation):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(marker)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.orange)
                Text(MarkdownInlineRenderer.render(block.content))
                    .font(.system(size: 16))
                    .lineSpacing(5)
                    .foregroundStyle(.primary)
            }
            .padding(.leading, CGFloat(indentation) * 18)
            .padding(.bottom, 7)

        case .code:
            ScrollView(.horizontal) {
                Text(block.content)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.purple)
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .padding(.vertical, 6)
            .padding(.bottom, 12)

        case .divider:
            Rectangle()
                .fill(.blue.opacity(0.3))
                .frame(height: 1)
                .padding(.vertical, 20)

        case .space:
            Color.clear.frame(height: 7)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .system(size: 29, weight: .bold)
        case 2: .system(size: 23, weight: .bold)
        case 3: .system(size: 19, weight: .semibold)
        default: .system(size: 17, weight: .semibold)
        }
    }
}

struct MarkdownReadingBlock: Identifiable {
    enum Kind {
        case heading(level: Int)
        case paragraph
        case quote
        case unorderedList(indentation: Int)
        case orderedList(marker: String, indentation: Int)
        case code
        case divider
        case space
    }

    let id: Int
    let kind: Kind
    let content: String
}

enum MarkdownInlineRenderer {
    static func render(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
    }
}

enum MarkdownReadingParser {
    static func parse(_ source: String) -> [MarkdownReadingBlock] {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [MarkdownReadingBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var isInsideCodeFence = false

        func append(_ kind: MarkdownReadingBlock.Kind, _ content: String = "") {
            blocks.append(.init(id: blocks.count, kind: kind, content: content))
        }

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            append(.paragraph, paragraphLines.joined(separator: "\n"))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                if isInsideCodeFence {
                    append(.code, codeLines.joined(separator: "\n"))
                    codeLines.removeAll(keepingCapacity: true)
                }
                isInsideCodeFence.toggle()
                continue
            }

            if isInsideCodeFence {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                if blocks.last.map({ !isSpace($0.kind) }) ?? false {
                    append(.space)
                }
                continue
            }

            if let heading = heading(in: trimmed) {
                flushParagraph()
                append(.heading(level: heading.level), heading.content)
            } else if isDivider(trimmed) {
                flushParagraph()
                append(.divider)
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                let content = String(trimmed.dropFirst())
                    .trimmingCharacters(in: .whitespaces)
                append(.quote, content)
            } else if let item = unorderedItem(in: line) {
                flushParagraph()
                append(.unorderedList(indentation: item.indentation), item.content)
            } else if let item = orderedItem(in: line) {
                flushParagraph()
                append(
                    .orderedList(
                        marker: item.marker,
                        indentation: item.indentation
                    ),
                    item.content
                )
            } else {
                paragraphLines.append(line)
            }
        }

        flushParagraph()
        if isInsideCodeFence && !codeLines.isEmpty {
            append(.code, codeLines.joined(separator: "\n"))
        }
        while blocks.last.map({ isSpace($0.kind) }) ?? false {
            blocks.removeLast()
        }
        return blocks
    }

    private static func heading(in line: String) -> (level: Int, content: String)? {
        let hashes = line.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count),
              line.dropFirst(hashes.count).first?.isWhitespace == true else {
            return nil
        }
        return (
            hashes.count,
            String(line.dropFirst(hashes.count))
                .trimmingCharacters(in: .whitespaces)
        )
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first else { return false }
        return (first == "-" || first == "*" || first == "_")
            && compact.allSatisfy { $0 == first }
    }

    private static func unorderedItem(
        in line: String
    ) -> (indentation: Int, content: String)? {
        let indentation = line.prefix(while: { $0 == " " }).count / 2
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first,
              "-+*".contains(marker),
              trimmed.dropFirst().first?.isWhitespace == true else { return nil }
        return (
            indentation,
            String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        )
    }

    private static func orderedItem(
        in line: String
    ) -> (marker: String, indentation: Int, content: String)? {
        let indentation = line.prefix(while: { $0 == " " }).count / 2
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        let remainder = trimmed.dropFirst(digits.count)
        guard let punctuation = remainder.first,
              punctuation == "." || punctuation == ")",
              remainder.dropFirst().first?.isWhitespace == true else { return nil }
        return (
            "\(digits)\(punctuation)",
            indentation,
            String(remainder.dropFirst()).trimmingCharacters(in: .whitespaces)
        )
    }

    private static func isSpace(_ kind: MarkdownReadingBlock.Kind) -> Bool {
        if case .space = kind { return true }
        return false
    }
}
