import Foundation
import Observation

enum EditProposalResolutionOutcome: Sendable {
    case applied(
        text: String,
        refreshedDocument: NoteDocument,
        settledLine: Int,
        isComplete: Bool,
        isExternal: Bool
    )
    case externalFileChanged(message: String)
}

enum EditProposalControllerError: LocalizedError {
    case staleDocument
    case externalReadFailed(Error)

    var errorDescription: String? {
        switch self {
        case .staleDocument:
            "文稿已在审阅期间发生变化，无法安全处理这处修改。"
        case .externalReadFailed(let error):
            "无法确认外部文件的最新内容：\(error.localizedDescription)"
        }
    }
}

@MainActor
@Observable
final class EditProposalController {
    var proposal: EditProposal?

    private let knowledgeBase: KnowledgeBaseService
    private let documentSession: DocumentSessionController
    private let revisions: RevisionController
    private var snapshottedProposalIDs: Set<UUID> = []

    init(
        knowledgeBase: KnowledgeBaseService,
        documentSession: DocumentSessionController,
        revisions: RevisionController
    ) {
        self.knowledgeBase = knowledgeBase
        self.documentSession = documentSession
        self.revisions = revisions
    }

    func resolve(
        hunkID: LineDiffHunk.ID,
        accepted: Bool,
        document: NoteDocument,
        currentText: String
    ) throws -> EditProposalResolutionOutcome? {
        guard let proposal else { return nil }
        guard proposal.canApply(
            to: document.relativePath,
            currentText: currentText
        ) else {
            throw EditProposalControllerError.staleDocument
        }
        if let externalChange = try refreshExternalProposalIfNeeded(
            proposal,
            document: document,
            currentText: currentText
        ) {
            return .externalFileChanged(message: externalChange)
        }

        let diff = LineDiff(
            original: proposal.original,
            replacement: proposal.replacement
        )
        guard let resolution = diff.resolving(
            hunkID: hunkID,
            accepted: accepted
        ) else { return nil }

        try snapshotIfNeeded(proposal, document: document)
        documentSession.cancelAutosave()
        let refreshed = try documentSession.writeSynchronously(
            resolution.settledText,
            to: document,
            using: knowledgeBase
        )
        documentSession.loadedText = resolution.settledText

        let isComplete = resolution.remainingReplacement == nil
        if let remainingReplacement = resolution.remainingReplacement {
            self.proposal = EditProposal(
                id: proposal.id,
                documentPath: proposal.documentPath,
                original: resolution.settledText,
                replacement: remainingReplacement,
                expectedDiskText: resolution.settledText
            )
        } else {
            self.proposal = nil
            snapshottedProposalIDs.remove(proposal.id)
        }
        revisions.load(for: document)
        return .applied(
            text: resolution.settledText,
            refreshedDocument: refreshed,
            settledLine: resolution.settledLine,
            isComplete: isComplete,
            isExternal: true
        )
    }

    func reset() {
        proposal = nil
        snapshottedProposalIDs.removeAll()
    }

    private func snapshotIfNeeded(
        _ proposal: EditProposal,
        document: NoteDocument
    ) throws {
        guard !snapshottedProposalIDs.contains(proposal.id) else { return }
        _ = try revisions.createSnapshot(
            text: proposal.original,
            document: document,
            name: "应用外部修改前"
        )
        _ = try revisions.createSnapshot(
            text: proposal.replacement,
            document: document,
            name: "外部修改完整版本"
        )
        snapshottedProposalIDs.insert(proposal.id)
    }

    private func refreshExternalProposalIfNeeded(
        _ proposal: EditProposal,
        document: NoteDocument,
        currentText: String
    ) throws -> String? {
        let latestDiskText: String
        do {
            latestDiskText = try knowledgeBase.read(document)
        } catch {
            throw EditProposalControllerError.externalReadFailed(error)
        }
        let expectedDiskText = proposal.expectedDiskText
            ?? proposal.replacement
        guard latestDiskText != expectedDiskText else { return nil }
        snapshottedProposalIDs.remove(proposal.id)
        self.proposal = EditProposal(
            documentPath: document.relativePath,
            original: currentText,
            replacement: latestDiskText
        )
        return "外部文件又有新修改，Diff 已更新，请重新确认。"
    }
}
