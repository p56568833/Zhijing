import SwiftUI

struct DiffReviewView: View {
    let store: AppStore
    let proposal: EditProposal
    private let diff: LineDiff
    private let presentation: InlineDiffPresentation
    @State private var decisions: [LineDiffHunk.ID: Bool] = [:]

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
        InlineDiffSourceEditor(
            presentation: presentation,
            proposalID: proposal.id,
            decisions: decisions,
            onDecision: decide
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func decide(hunkID: LineDiffHunk.ID, accepted: Bool) {
        guard diff.hunks.contains(where: { $0.id == hunkID }) else { return }
        var updatedDecisions = decisions
        updatedDecisions[hunkID] = accepted
        decisions = updatedDecisions

        let allHunkIDs = Set(diff.hunks.map(\.id))
        guard allHunkIDs.isSubset(of: Set(updatedDecisions.keys)) else { return }
        let acceptedHunkIDs = Set(updatedDecisions.compactMap { id, accepted in
            accepted ? id : nil
        })
        if acceptedHunkIDs.isEmpty {
            store.cancelEditProposal()
        } else {
            store.applyProposal(
                replacement: diff.applying(acceptedHunkIDs: acceptedHunkIDs)
            )
        }
    }
}
