import Observation

@MainActor
@Observable
final class DocumentFindController {
    var isVisible = false
    var options = DocumentFindOptions()
    private(set) var result = DocumentFindResult()
    private(set) var navigationRequest: DocumentFindNavigationRequest?

    func show() {
        isVisible = true
    }

    func hide() {
        isVisible = false
        options.query = ""
        result = DocumentFindResult()
        navigationRequest = nil
    }

    func navigate(_ direction: DocumentFindDirection) {
        isVisible = true
        navigationRequest = DocumentFindNavigationRequest(
            direction: direction
        )
    }

    func updateResult(_ result: DocumentFindResult) {
        guard self.result != result else { return }
        self.result = result
    }
}
