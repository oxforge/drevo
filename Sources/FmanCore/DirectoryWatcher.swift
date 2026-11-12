import CoreServices
import Foundation

/// Watches a set of folders with FSEvents and reports which of them changed.
/// Events are coalesced over `latency`; the handler runs on a private queue.
public final class DirectoryWatcher: @unchecked Sendable {
    public typealias Handler = (Set<String>) -> Void

    private let latency: CFTimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "fman.watcher")
    private var stream: FSEventStreamRef?
    private(set) public var watched: Set<String> = []
    private let lock = NSLock()

    public init(latency: CFTimeInterval = 0.2, handler: @escaping Handler) {
        self.latency = latency
        self.handler = handler
    }

    deinit { stopStream() }

    /// Replaces the watched folders (paths are standardized; no-op if unchanged).
    public func watch(_ urls: [URL]) {
        let paths = Set(urls.map { Self.normalize($0.path) })
        lock.lock()
        let same = paths == watched
        if !same { watched = paths }
        lock.unlock()
        guard !same else { return }
        stopStream()
        guard !paths.isEmpty else { return }
        startStream(Array(paths))
    }

    public static func normalize(_ path: String) -> String {
        let p = (path as NSString).standardizingPath
        let resolved = (p as NSString).resolvingSymlinksInPath
        return resolved.count > 1 && resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved
    }

    private func startStream(_ paths: [String]) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
            var changed = Set<String>()
            let watched = watcher.currentWatched
            for (i, raw) in list.enumerated() where i < count {
                let path = DirectoryWatcher.normalize(raw)
                let f = flags[i]
                if watched.contains(path) { changed.insert(path) }
                // Subtree rescans or a vanished root: refresh everything at or under it.
                if f & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 || f & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
                    changed.formUnion(watched.filter { $0.hasPrefix(path) || path.hasPrefix($0) })
                }
            }
            if !changed.isEmpty { watcher.handler(changed) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        lock.lock(); stream = s; lock.unlock()
    }

    private var currentWatched: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return watched
    }

    private func stopStream() {
        lock.lock()
        let s = stream
        stream = nil
        lock.unlock()
        guard let s else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }

    public func stop() {
        lock.lock(); watched = []; lock.unlock()
        stopStream()
    }
}
