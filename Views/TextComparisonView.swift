import SwiftUI

struct TextComparisonView: View {
    let originalTitle: String
    let original: String
    let replacementTitle: String
    let replacement: String

    private let diff: LineDiff

    init(
        originalTitle: String,
        original: String,
        replacementTitle: String,
        replacement: String
    ) {
        self.originalTitle = originalTitle
        self.original = original
        self.replacementTitle = replacementTitle
        self.replacement = replacement
        diff = LineDiff(original: original, replacement: replacement)
    }

    var body: some View {
        HSplitView {
            ComparisonColumn(
                title: originalTitle,
                lines: diff.originalLines,
                changedOffsets: diff.removedOffsets,
                tint: .red
            )
            ComparisonColumn(
                title: replacementTitle,
                lines: diff.replacementLines,
                changedOffsets: diff.insertedOffsets,
                tint: .green
            )
        }
    }
}

private struct ComparisonColumn: View {
    let title: String
    let lines: [String]
    let changedOffsets: Set<Int>
    let tint: Color

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .frame(height: 40)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { offset, line in
                        HStack(alignment: .top, spacing: 9) {
                            Text("\(offset + 1)")
                                .foregroundStyle(.tertiary)
                                .frame(width: 34, alignment: .trailing)
                            Text(line.isEmpty ? " " : line)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            changedOffsets.contains(offset)
                                ? tint.opacity(0.12)
                                : Color.clear
                        )
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 320)
    }
}
