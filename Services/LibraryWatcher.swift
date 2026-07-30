import CoreServices
import Foundation

final class LibraryWatcher {
    private final class EventHandlerBox {
        let handle: @Sendable ([URL]) -> Void

        init(handle: @escaping @Sendable ([URL]) -> Void) {
            self.handle = handle
        }
    }

    private let queue = DispatchQueue(
        label: "com.zhijing.library-watcher",
        qos: .utility
    )
    private var stream: FSEventStreamRef?
    private var handlerBox: EventHandlerBox?

    deinit {
        queue.sync {
            stopOnQueue()
        }
    }

    func start(
        root: URL,
        additionalFiles: [URL] = [],
        excludedFolders: [String],
        onChange: @escaping @Sendable ([URL]) -> Void
    ) {
        let root = root.standardizedFileURL
        let rootPath = root.path
        let exclusions = Set(excludedFolders)
        let externalFilePaths = Set(
            additionalFiles.map { $0.standardizedFileURL.path }
        )
        let externalParentPaths = Set(
            additionalFiles.map {
                $0.deletingLastPathComponent().standardizedFileURL.path
            }
        )
        let watchedPaths = Array(Set([rootPath]).union(externalParentPaths)).sorted()
        let handler = EventHandlerBox { urls in
            let filtered = urls.filter { url in
                let path = url.standardizedFileURL.path
                return Self.shouldInclude(
                    url,
                    rootPath: rootPath,
                    excludedFolders: exclusions
                ) || externalFilePaths.contains(path)
                    || externalParentPaths.contains(path)
            }
            if !filtered.isEmpty {
                onChange(filtered)
            }
        }

        queue.sync {
            stopOnQueue()
            startOnQueue(paths: watchedPaths, handler: handler)
        }
    }

    func stop() {
        queue.sync {
            stopOnQueue()
        }
    }

    private func startOnQueue(paths: [String], handler: EventHandlerBox) {
        handlerBox = handler
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.handleEvents,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.35,
            flags
        ) else {
            handlerBox = nil
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            handlerBox = nil
            return
        }
    }

    private func stopOnQueue() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        handlerBox = nil
    }

    private static let handleEvents: FSEventStreamCallback = {
        _, info, eventCount, eventPaths, _, _ in
        guard let info else { return }
        let handler = Unmanaged<EventHandlerBox>
            .fromOpaque(info)
            .takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
        let urls = paths.prefix(eventCount).map {
            URL(filePath: $0).standardizedFileURL
        }
        handler.handle(urls)
    }

    static func shouldInclude(
        _ url: URL,
        rootPath: String,
        excludedFolders: Set<String>
    ) -> Bool {
        let path = url.standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return false }
        guard path != rootPath else { return true }
        guard !AnnotationPersistenceService.isPersistenceFile(url) else {
            return false
        }
        let relative = path.dropFirst(rootPath.count + 1)
        let components = relative.split(separator: "/").map(String.init)
        return components.allSatisfy { !excludedFolders.contains($0) }
    }
}
