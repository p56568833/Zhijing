import CoreServices
import Foundation

final class LibraryWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.zhijing.library-watcher",
        qos: .utility
    )
    private var stream: FSEventStreamRef?
    private var onChange: (@Sendable ([URL]) -> Void)?

    func start(
        root: URL,
        additionalFiles: [URL] = [],
        excludedFolders: [String],
        onChange: @escaping @Sendable ([URL]) -> Void
    ) {
        stop()
        let rootPath = root.standardizedFileURL.path
        let exclusions = Set(excludedFolders)
        let externalFilePaths = Set(
            additionalFiles.map { $0.standardizedFileURL.path }
        )
        let externalParentPaths = Set(
            additionalFiles.map {
                $0.deletingLastPathComponent().standardizedFileURL.path
            }
        )
        self.onChange = { urls in
            let filtered = urls.filter {
                let path = $0.standardizedFileURL.path
                return Self.shouldInclude(
                    $0,
                    rootPath: rootPath,
                    excludedFolders: exclusions
                ) || externalFilePaths.contains(path)
                    || externalParentPaths.contains(path)
            }
            if !filtered.isEmpty {
                onChange(filtered)
            }
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagNoDefer
        )
        let paths = ([root.standardizedFileURL.path] + Array(externalParentPaths))
            .sorted() as CFArray
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.handleEvents,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.35,
            flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else {
            onChange = nil
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        onChange = nil
    }

    private static let handleEvents: FSEventStreamCallback = {
        _, info, eventCount, eventPaths, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<LibraryWatcher>
            .fromOpaque(info)
            .takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
        let urls = paths.prefix(eventCount).map {
            URL(filePath: $0).standardizedFileURL
        }
        watcher.onChange?(urls)
    }

    static func shouldInclude(
        _ url: URL,
        rootPath: String,
        excludedFolders: Set<String>
    ) -> Bool {
        let path = url.standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return false }
        guard path != rootPath else { return true }
        let relative = path.dropFirst(rootPath.count + 1)
        let components = relative.split(separator: "/").map(String.init)
        return components.allSatisfy { !excludedFolders.contains($0) }
    }
}
