import Foundation

final class ChatPersistenceService: @unchecked Sendable {
    private let directoryOverride: URL?
    private let queue = DispatchQueue(label: "com.zhijing.chat-persistence", qos: .utility)
    private let lock = NSLock()
    private var pendingChats: [String: [ChatMessage]]?
    private var workerScheduled = false
    private var lastError: Error?

    init(directoryOverride: URL? = nil) {
        self.directoryOverride = directoryOverride
    }

    func load(legacyData: Data? = nil) -> [String: [ChatMessage]] {
        (try? loadStrict(legacyData: legacyData)) ?? [:]
    }

    func loadStrict(
        legacyData: Data? = nil
    ) throws -> [String: [ChatMessage]] {
        let decoder = JSONDecoder()
        let url = try storageURL()
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            return try decoder.decode([String: [ChatMessage]].self, from: data)
        }
        guard let legacyData else { return [:] }
        return try decoder.decode([String: [ChatMessage]].self, from: legacyData)
    }

    func save(_ chats: [String: [ChatMessage]]) {
        lock.lock()
        pendingChats = chats
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

    func saveSynchronously(_ chats: [String: [ChatMessage]]) throws {
        save(chats)
        queue.sync {}
        lock.lock(); defer { lock.unlock() }
        if let lastError {
            throw lastError
        }
    }

    private func drainPendingSaves() {
        while true {
            lock.lock()
            guard let chats = pendingChats else {
                workerScheduled = false
                lock.unlock()
                return
            }
            pendingChats = nil
            lock.unlock()

            do {
                try write(chats)
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

    private func write(_ chats: [String: [ChatMessage]]) throws {
        let url = try storageURL()
        let existingData: Data?
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            _ = try JSONDecoder().decode(
                [String: [ChatMessage]].self,
                from: data
            )
            existingData = data
        } else {
            existingData = nil
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(chats)
        guard data != existingData else { return }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func storageURL() throws -> URL {
        if let directoryOverride {
            return directoryOverride.appending(path: "Chats.json")
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appending(path: "知境/Chats.json")
    }
}
