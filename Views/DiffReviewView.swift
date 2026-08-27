import SwiftUI

struct DiffReviewView: View {
    let store: AppStore
    let proposal: EditProposal
    private let presentation: InlineDiffPresentation

    init(store: AppStore, proposal: EditProposal) {
        self.store = store
        self.proposal = proposal
        let diff = LineDiff(
            original: proposal.original,
            replacement: proposal.replacement
        )
        presentation = InlineDiffPresentation(diff: diff)
    }

    var body: some View {
        InlineDiffSourceEditor(
            presentation: presentation,
            proposalID: proposal.id,
            onDecision: decide
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ZhijingTheme.paper)
    }

    private func decide(
        hunkID: LineDiffHunk.ID,
        accepted: Bool,
        viewportFraction: Double
    ) {
        store.resolveProposalHunk(
            hunkID: hunkID,
            accepted: accepted,
            viewportFraction: viewportFraction
        )
    }
}
