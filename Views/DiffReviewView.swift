import SwiftUI

struct DiffReviewView: View {
    let store: AppStore
    let proposal: EditProposal
    private let diff: LineDiff
    @State private var acceptedHunkIDs: Set<LineDiffHunk.ID>
    @Environment(\.dismiss) private var dismiss

    init(store: AppStore, proposal: EditProposal) {
        self.store = store
        self.proposal = proposal
        let diff = LineDiff(
            original: proposal.original,
            replacement: proposal.replacement
        )
        self.diff = diff
        _acceptedHunkIDs = State(
            initialValue: Set(diff.hunks.filter {
                !Self.isOutsideSelection(
                    hunk: $0,
                    selectionLineRange: proposal.selectionLineRange
                )
            }.map(\.id))
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(diff.hunks) { hunk in
                        DiffHunkView(
                            hunk: hunk,
                            isOutsideSelection: isOutsideSelection(hunk),
                            outsideReason: proposal.outsideSelectionReason,
                            isAccepted: Binding(
                                get: { acceptedHunkIDs.contains(hunk.id) },
                                set: { accepted in
                                    if accepted {
                                        acceptedHunkIDs.insert(hunk.id)
                                    } else {
                                        acceptedHunkIDs.remove(hunk.id)
                                    }
                                }
                            )
                        )
                    }
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(minWidth: 920, minHeight: 640)
    }

    private func isOutsideSelection(_ hunk: LineDiffHunk) -> Bool {
        Self.isOutsideSelection(
            hunk: hunk,
            selectionLineRange: proposal.selectionLineRange
        )
    }

    private static func isOutsideSelection(
        hunk: LineDiffHunk,
        selectionLineRange: Range<Int>?
    ) -> Bool {
        guard let selectionLineRange else { return false }
        if hunk.originalRange.isEmpty {
            return !selectionLineRange.contains(hunk.originalRange.lowerBound)
        }
        return hunk.originalRange.lowerBound < selectionLineRange.lowerBound ||
            hunk.originalRange.upperBound > selectionLineRange.upperBound
    }

    private var header: some View {
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
            VStack(alignment: .trailing, spacing: 6) {
                Text("-\(diff.removedOffsets.count)  +\(diff.insertedOffsets.count)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("全部保留") {
                        acceptedHunkIDs.removeAll()
                    }
                    Button("全部接受") {
                        acceptedHunkIDs = Set(diff.hunks.map(\.id))
                    }
                }
                .font(.caption)
                .buttonStyle(.link)
            }
        }
        .padding(18)
    }

    private var footer: some View {
        HStack {
            Label("应用前会自动保存一个版本快照", systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("已选择 \(acceptedHunkIDs.count) / \(diff.hunks.count) 段")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("取消") {
                store.editProposal = nil
                dismiss()
            }
            Button("应用所选修改") {
                store.applyProposal(
                    replacement: diff.applying(
                        acceptedHunkIDs: acceptedHunkIDs
                    )
                )
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(acceptedHunkIDs.isEmpty)
        }
        .padding(14)
    }
}

private struct DiffHunkView: View {
    let hunk: LineDiffHunk
    let isOutsideSelection: Bool
    let outsideReason: String?
    @Binding var isAccepted: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("变更段 \(hunk.id + 1)")
                    .font(.headline)
                Text("-\(hunk.removedCount)  +\(hunk.insertedCount)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if isOutsideSelection {
                    Label("连带修改", systemImage: "arrow.triangle.branch")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Picker("处理方式", selection: $isAccepted) {
                    Text("保留原文").tag(false)
                    Text("接受修改").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            if isOutsideSelection {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "info.circle")
                    Text(outsideReason ?? "AI 认为这部分需要一起调整；请确认理由后再接受。")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }

            Divider()

            HStack(alignment: .top, spacing: 0) {
                DiffHunkColumn(
                    title: "原文",
                    lines: hunk.originalLines,
                    startingLine: hunk.originalRange.lowerBound + 1,
                    tint: .red
                )
                Divider()
                DiffHunkColumn(
                    title: "AI 修改",
                    lines: hunk.replacementLines,
                    startingLine: hunk.replacementRange.lowerBound + 1,
                    tint: .green
                )
            }
        }
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isAccepted ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.18),
                    lineWidth: 1
                )
        }
    }
}

private struct DiffHunkColumn: View {
    let title: String
    let lines: [String]
    let startingLine: Int
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(height: 32)
            Divider()
            if lines.isEmpty {
                Text("（无内容）")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { offset, line in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(startingLine + offset)")
                                .foregroundStyle(.tertiary)
                                .frame(width: 34, alignment: .trailing)
                            Text(line.isEmpty ? " " : line)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(tint.opacity(0.10))
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
