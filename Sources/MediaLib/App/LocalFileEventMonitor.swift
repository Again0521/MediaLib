import CoreServices
import Foundation

struct LocalFileSystemChange: Sendable {
    let path: String
    let flags: FSEventStreamEventFlags

    var requiresFullScan: Bool {
        let fullScanFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs |
                kFSEventStreamEventFlagUserDropped |
                kFSEventStreamEventFlagKernelDropped |
                kFSEventStreamEventFlagRootChanged
        )
        return flags & fullScanFlags != 0
    }

    var isRemovedOrRenamedDirectory: Bool {
        let isDirectory = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
        let structuralFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemRemoved |
                kFSEventStreamEventFlagItemRenamed
        )
        return isDirectory && flags & structuralFlags != 0
    }
}

final class LocalFileEventMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MediaLIB.FileEvents", qos: .utility)
    private let callback: @Sendable ([LocalFileSystemChange]) -> Void
    private var stream: FSEventStreamRef?
    private var watchedPaths: [String] = []

    init(callback: @escaping @Sendable ([LocalFileSystemChange]) -> Void) {
        self.callback = callback
    }

    deinit {
        stop()
    }

    func update(paths: [String]) {
        let nextPaths = Array(Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })).sorted()
        guard nextPaths != watchedPaths else { return }
        stop()
        watchedPaths = nextPaths
        guard !nextPaths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagWatchRoot |
                kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil,
            { _, info, count, eventPaths, eventFlags, _ in
                guard let info else { return }
                let monitor = Unmanaged<LocalFileEventMonitor>.fromOpaque(info).takeUnretainedValue()
                let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                var changes: [LocalFileSystemChange] = []
                changes.reserveCapacity(count)
                for index in 0..<count {
                    changes.append(
                        LocalFileSystemChange(
                            path: String(cString: paths[index]),
                            flags: eventFlags[index]
                        )
                    )
                }
                monitor.callback(changes)
            },
            &context,
            nextPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.75,
            flags
        ) else {
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
