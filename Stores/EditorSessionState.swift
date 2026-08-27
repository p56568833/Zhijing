import Foundation
import Observation

@MainActor
@Observable
final class EditorSessionState {
    var selectedDocument: NoteDocument?
    private(set) var text = ""
    private(set) var contentRevision = 0
    private(set) var navigationRequest: EditorNavigationRequest?
    private(set) var selection: EditorTextSelection?
    private(set) var wordCount = 0
    private(set) var speakingDurationLabel = DocumentMetrics(markdown: "")
        .speakingDurationLabel
    private(set) var selectionMetrics: DocumentMetrics?
    var saveState: SaveState = .idle

    @ObservationIgnored
    private var wordCountTask: Task<Void, Never>?

    func acceptUserText(_ text: String) {
        self.text = text
        scheduleWordCount(for: text)
    }

    func replaceText(_ text: String) {
        self.text = text
        contentRevision &+= 1
        scheduleWordCount(for: text, delay: .zero)
    }

    func updateSelection(_ selection: EditorTextSelection?) {
        self.selection = selection
        updateMetricSelection(selection?.text)
    }

    func updateMetricSelection(_ text: String?) {
        guard let text, !text.isEmpty else {
            selectionMetrics = nil
            return
        }
        selectionMetrics = DocumentMetrics(markdown: text)
    }

    func navigate(to request: EditorNavigationRequest?) {
        navigationRequest = request
    }

    func clearDocument() {
        wordCountTask?.cancel()
        selectedDocument = nil
        selection = nil
        wordCount = 0
        speakingDurationLabel = DocumentMetrics(markdown: "").speakingDurationLabel
        selectionMetrics = nil
        replaceText("")
    }

    func scheduleWordCount(
        for text: String,
        delay: Duration = .milliseconds(280)
    ) {
        wordCountTask?.cancel()
        wordCountTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let metrics = await Task.detached(priority: .utility) {
                DocumentMetrics(markdown: text)
            }.value
            guard let self, !Task.isCancelled, self.text == text else { return }
            wordCount = metrics.count
            speakingDurationLabel = metrics.speakingDurationLabel
        }
    }

    func waitForWordCountUpdate() async {
        await wordCountTask?.value
    }
}
