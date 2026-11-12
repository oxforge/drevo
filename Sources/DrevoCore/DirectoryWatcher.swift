import CoreServices
import Foundation

/// Watches a set of folders with FSEvents and reports which of them changed.
/// Events are coalesced over `latency`; the handler runs on a private queue. Once
/// `stop()` or a new `watch(_:)` returns (or the watcher is released), no call of the
/// handler for the folders watched before is running or will start — so the handler
/// must not wait for the thread that stops the watcher.
public final class DirectoryWatcher: @unchecked Sendable {
    public typealias Handler = (Set<String>) -> Void

    /// What the FSEvents callback works with. The stream keeps it alive, so a callback
    /// that is under way while the watcher goes away never touches freed memory.
    private final class State {
        let handler: Handler
        private let lock = NSLock()
        private var folders: Set<String> = []

        init(handler: @escaping Handler) {
            self.handler = handler
        }

        var watched: Set<String> {
            lock.lock(); defer { lock.unlock() }
            return folders
        }

        /// Sets the watched folders; false if they were these already.
        func replaceWatched(_ paths: Set<String>) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard paths != folders else { return false }
            folders = paths
            return true
        }
    }

    private let latency: CFTimeInterval
    private let state: State
    private let queue = DispatchQueue(label: "drevo.watcher")
    /// Marks the watcher's queue, to tell a stop that comes from the handler itself.
    private let queueKey = DispatchSpecificKey<Bool>()
    private var stream: FSEventStreamRef?
    private let streamLock = NSLock()

    public var watched: Set<String> { state.watched }

    public init(latency: CFTimeInterval = 0.2, handler: @escaping Handler) {
        self.latency = latency
        self.state = State(handler: handler)
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { stopStream() }

    /// Replaces the watched folders (paths are standardized; no-op if unchanged).
    public func watch(_ urls: [URL]) {
        let paths = Set(urls.map { Self.normalize($0.path) })
        guard state.replaceWatched(paths) else { return }
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
        // The stream retains the state for as long as it exists (and releases it with
        // itself); the callback gets the state, never the watcher.
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(state).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<State>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<State>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let state = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
            var changed = Set<String>()
            let watched = state.watched
            for (i, raw) in list.enumerated() where i < count {
                let path = DirectoryWatcher.normalize(raw)
                let f = flags[i]
                if watched.contains(path) { changed.insert(path) }
                // Subtree rescans or a vanished root: refresh everything at or under it.
                if f & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 || f & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
                    changed.formUnion(watched.filter { $0.hasPrefix(path) || path.hasPrefix($0) })
                }
            }
            if !changed.isEmpty { state.handler(changed) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        streamLock.lock(); stream = s; streamLock.unlock()
    }

    private func stopStream() {
        streamLock.lock()
        let s = stream
        stream = nil
        streamLock.unlock()
        guard let s else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        // Invalidating doesn't wait for a callback that is already running on the queue.
        if DispatchQueue.getSpecific(key: queueKey) == true {
            // Called from the handler: this is that callback. The stream goes once it
            // has returned.
            nonisolated(unsafe) let finished = s
            queue.async { FSEventStreamRelease(finished) }
        } else {
            queue.sync {}
            FSEventStreamRelease(s)
        }
    }

    public func stop() {
        _ = state.replaceWatched([])
        stopStream()
    }
}
