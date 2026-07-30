import Foundation
import Observation

@MainActor
@Observable
final class LibrarySearchController {
    var query = ""
    var results: [SearchHit] = []

    @ObservationIgnored
    private var searchTask: Task<Void, Never>?
    private let service: KnowledgeBaseService
    private let delay: Duration

    init(
        service: KnowledgeBaseService,
        delay: Duration = .milliseconds(180)
    ) {
        self.service = service
        self.delay = delay
    }

    func perform(documents: [NoteDocument]) {
        searchTask?.cancel()
        let requestedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !requestedQuery.isEmpty else {
            results = []
            searchTask = nil
            return
        }

        let service = service
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let matches = await Task.detached(priority: .userInitiated) {
                service.search(
                    query: requestedQuery,
                    documents: documents
                )
            }.value
            guard !Task.isCancelled,
                  query.trimmingCharacters(in: .whitespacesAndNewlines)
                    == requestedQuery else { return }
            results = matches
        }
    }

    func reset() {
        searchTask?.cancel()
        searchTask = nil
        query = ""
        results = []
    }

    func waitForPendingSearch() async {
        await searchTask?.value
    }
}
