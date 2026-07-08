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
        excludedFolders: [String],
        onChange: @escaping @Sendable ([URL]) -> Void
    ) {
        stop()
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )
        let paths = [root.path] as CFArray
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
}
