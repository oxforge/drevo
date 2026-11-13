import Foundation
import Testing
@testable import DrevoCore

@Test func reportsChangesInWatchedFolderOnly() throws {
    let tmp = TempDir()
    let a = tmp.dir("a")
    let b = tmp.dir("b")
    let fence = tmp.dir("fence")
    let lock = NSLock()
    var seen = Set<String>()
    let reported = DispatchSemaphore(value: 0)
    let w = DirectoryWatcher(latency: 0.05) { paths in
        lock.lock(); seen.formUnion(paths); lock.unlock()
        reported.signal()
    }
    defer { w.stop() }
    func reports() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return seen
    }
    let deadline = Date().addingTimeInterval(30)
    /// Changes the unwatched folder and then `folder`, again and again, until the watcher
    /// reports `folder` or the deadline passes.
    func changeUntilReported(_ folder: URL) -> Bool {
        let path = DirectoryWatcher.normalize(folder.path)
        var attempt = 0
        while !reports().contains(path) {
            guard Date() < deadline else { return false }
            attempt += 1
            tmp.file("b/ignored-\(folder.lastPathComponent)-\(attempt).txt")
            try? Data().write(to: folder.appendingPathComponent("new-\(attempt).txt"))
            _ = reported.wait(timeout: .now() + 0.25)
        }
        return true
    }

    w.watch([a, fence])
    // The stream starts asynchronously and reports only what happens after it started, so
    // the change is repeated until it is noticed rather than made once after a guessed delay.
    #expect(changeUntilReported(a), "a change in a watched folder was never reported")
    // The stream is running now, and events are delivered in the order they happened: once
    // the change in `fence` is reported, the one made in `b` just before it has been handled.
    #expect(changeUntilReported(fence), "a change in the second watched folder was never reported")
    #expect(reports() == [DirectoryWatcher.normalize(a.path), DirectoryWatcher.normalize(fence.path)])
    #expect(!reports().contains(DirectoryWatcher.normalize(b.path)))
}

@Test func normalizesPaths() {
    #expect(DirectoryWatcher.normalize("/tmp/") == DirectoryWatcher.normalize("/private/tmp"))
}

/// A watcher released while FSEvents is delivering "the watched folder is gone": the
/// callback under way must not touch a watcher that no longer exists (it crashed, now
/// and then, when a window closed as a folder it showed was deleted).
@Test func releasingAWatcherWhileItsFolderDisappearsIsSafe() {
    let tmp = TempDir()
    let lock = NSLock()
    var reports = 0
    for i in 0..<400 {
        let folder = tmp.dir("watched-\(i)")
        var watcher: DirectoryWatcher? = DirectoryWatcher(latency: 0) { _ in
            lock.lock(); reports += 1; lock.unlock()
        }
        watcher?.watch([folder])
        tmp.file("watched-\(i)/a.txt")
        // Let the stream start now and then, so that there are events to deliver…
        if i % 4 != 0 { usleep(UInt32(i % 5) * 2_000) }
        tmp.file("watched-\(i)/b.txt")
        try? FileManager.default.removeItem(at: folder)
        // …and let the release fall before, into and after their delivery.
        usleep(UInt32(i % 9) * 250)
        if i % 3 == 0 { watcher?.stop() }
        watcher = nil
    }
    // Nothing is reported once a watcher is gone.
    lock.lock(); let atRelease = reports; lock.unlock()
    usleep(200_000)
    lock.lock(); let later = reports; lock.unlock()
    #expect(later == atRelease)
}

/// Stopping from inside the handler (on the watcher's own queue) neither deadlocks nor crashes.
@Test func aWatcherCanBeStoppedFromItsOwnHandler() {
    let tmp = TempDir()
    let folder = tmp.dir("watched")
    let stopped = DispatchSemaphore(value: 0)
    let box = WatcherBox()
    box.watcher = DirectoryWatcher(latency: 0) { _ in
        box.watcher?.stop()
        box.watcher = nil
        stopped.signal()
    }
    box.watcher?.watch([folder])
    let deadline = Date().addingTimeInterval(30)
    var done = false
    var attempt = 0
    while !done, Date() < deadline {
        attempt += 1
        tmp.file("watched/new-\(attempt).txt")
        done = stopped.wait(timeout: .now() + 0.25) == .success
    }
    #expect(done, "the handler never ran")
}

private final class WatcherBox: @unchecked Sendable {
    var watcher: DirectoryWatcher?
}
