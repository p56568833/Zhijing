import Foundation

@MainActor
final class ExternalChangeMonitor {
    private let watcher: any LibraryWatching
    private let debounceDelay: Duration
    private var refreshTask: Task<Void, Never>?
    private var pendingURLs: Set<URL> = []
    private var onChanges: (@MainActor (Set<URL>) async -> Void)?

    init(
        watcher: any LibraryWatching = LibraryWatcher(),
        debounceDelay: Duration = .milliseconds(180)
    ) {
        self.watcher = watcher
        self.debounceDelay = debounceDelay
    }

    func start(
        libraryRoot: URL?,
        additionalFiles: [URL],
        excludedFolders: [String],
        onChanges: @escaping @MainActor (Set<URL>) async -> Void
    ) {
        stop()
        guard let libraryRoot else { return }
        self.onChanges = onChanges
        watcher.start(
            root: libraryRoot,
            additionalFiles: additionalFiles,
            excludedFolders: excludedFolders
        ) { [weak self] changedURLs in
            Task { @MainActor [weak self] in
                self?.receive(changedURLs)
            }
        }
    }

    func receive(_ changedURLs: [URL]) {
        pendingURLs.formUnion(changedURLs.map(\.standardizedFileURL))
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: debounceDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let changedURLs = pendingURLs
            pendingURLs.removeAll()
            await onChanges?(changedURLs)
        }
    }

    func stop() {
        watcher.stop()
        refreshTask?.cancel()
        refreshTask = nil
        pendingURLs.removeAll()
        onChanges = nil
    }

    func waitForPendingChanges() async {
        await refreshTask?.value
    }
}
