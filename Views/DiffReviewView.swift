import SwiftUI

struct DiffReviewView: View {
    let store: AppStore
    let proposal: EditProposal
    private let diff: LineDiff
    private let presentation: InlineDiffPresentation

    init(store: AppStore, proposal: EditProposal) {
        self.store = store
        self.proposal = proposal
        let diff = LineDiff(
            original: proposal.original,
            replacement: proposal.replacement
        )
        self.diff = diff
        presentation = InlineDiffPresentation(diff: diff)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            InlineDiffSourceEditor(
                presentation: presentation,
                proposalID: proposal.id
            )
            reviewActions
                .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var reviewActions: some View {
        HStack(spacing: 10) {
            Label(reviewTitle, systemImage: reviewIcon)
                .font(.callout.weight(.medium))
            Text("−\(diff.removedOffsets.count)  +\(diff.insertedOffsets.count)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Divider()
                .frame(height: 20)
            Button("不同意") {
                store.cancelEditProposal()
            }
            .keyboardShortcut(.cancelAction)
            Button("同意") {
                store.applyProposal()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator.opacity(0.7), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
        .help(reviewHelp)
    }

    private var reviewTitle: String {
        switch proposal.source {
        case .assistant: "AI 修改"
        case .externalFile: "外部修改"
        }
    }

    private var reviewIcon: String {
        switch proposal.source {
        case .assistant: "sparkles"
        case .externalFile: "arrow.triangle.2.circlepath"
        }
    }

    private var reviewHelp: String {
        switch proposal.source {
        case .assistant:
            "红色为原文，绿色为 AI 修改；同意前会保存版本快照。"
        case .externalFile:
            "红色为原文，绿色为外部修改；不同意时会保存外部版本后恢复原稿。"
        }
    }
}
