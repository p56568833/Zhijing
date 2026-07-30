import Foundation

final class AnnotationPersistenceService: @unchecked Sendable {
    private let directoryOverride: URL?
    private let queue = DispatchQueue(
        label: "com.zhijing.annotation-persistence",
        qos: .utility
    )
    private let lock = NSLock()
    private var pendingAnnotations: [String: [TextAnnotation]]?
    private var workerScheduled = false
    private var lastError: Error?

    init(directoryOverride: URL? = nil) {
        self.directoryOverride = directoryOverride
    }

    func load() -> [String: [TextAnnotation]] {
        guard let data = try? Data(contentsOf: storageURL()),
              let value = try? JSONDecoder().decode(
                  [String: [TextAnnotation]].self,
                  from: data
              ) else { return [:] }
        return value
    }

    func save(_ annotations: [String: [TextAnnotation]]) {
        lock.lock()
        pendingAnnotations = annotations
        guard !workerScheduled else {
            lock.unlock()
            return
        }
        workerScheduled = true
        lock.unlock()

        queue.async { [weak self] in
            self?.drainPendingSaves()
        }
    }

    func saveSynchronously(
        _ annotations: [String: [TextAnnotation]]
    ) throws {
        save(annotations)
        queue.sync {}
        lock.lock(); defer { lock.unlock() }
        if let lastError { throw lastError }
    }

    private func drainPendingSaves() {
        while true {
            lock.lock()
            guard let annotations = pendingAnnotations else {
                workerScheduled = false
                lock.unlock()
                return
            }
            pendingAnnotations = nil
            lock.unlock()

            do {
                try write(annotations)
                lock.lock()
                lastError = nil
                lock.unlock()
            } catch {
                lock.lock()
                lastError = error
                lock.unlock()
            }
        }
    }

    private func write(
        _ annotations: [String: [TextAnnotation]]
    ) throws {
        let url = try storageURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(annotations).write(to: url, options: .atomic)
    }

    private func storageURL() throws -> URL {
        if let directoryOverride {
            return directoryOverride.appending(path: "Annotations.json")
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appending(path: "知境/Annotations.json")
    }
}
