import SwiftUI

struct DiffReviewView: View {
    let store: AppStore
    let proposal: EditProposal
    @Environment(\.dismiss) private var dismiss

    private var diff: LineDiff {
        LineDiff(original: proposal.original, replacement: proposal.replacement)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("查看 AI 修改")
                        .font(.title2.weight(.semibold))
                    Text(proposal.instruction)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text("-\(diff.removedOffsets.count)  +\(diff.insertedOffsets.count)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            Divider()
            HSplitView {
                DiffColumn(
                    title: "修改前",
                    text: proposal.original,
                    changedOffsets: diff.removedOffsets,
                    tint: .red
                )
                DiffColumn(
                    title: "修改后",
                    text: proposal.replacement,
                    changedOffsets: diff.insertedOffsets,
                    tint: .green
                )
            }
            Divider()
            HStack {
                Label("接受前会自动保存一个版本快照", systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("拒绝") {
                    store.editProposal = nil
                    dismiss()
                }
                Button("接受全部") {
                    store.applyProposal()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(14)
        }
        .frame(minWidth: 920, minHeight: 640)
    }
}

private struct DiffColumn: View {
    let title: String
    let text: String
    let changedOffsets: Set<Int>
    let tint: Color

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .frame(height: 42)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { offset, line in
                        HStack(alignment: .top, spacing: 10) {
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
                        .background(changedOffsets.contains(offset) ? tint.opacity(0.14) : .clear)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var lines: [String] {
        text.components(separatedBy: .newlines)
    }
}
