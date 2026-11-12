import Foundation
import Testing
@testable import FmanCore

@Test func reportsChangesInWatchedFolderOnly() throws {
    let tmp = TempDir()
    let a = tmp.dir("a")
    let b = tmp.dir("b")
    let lock = NSLock()
    var seen = Set<String>()
    let changed = DispatchSemaphore(value: 0)
    let w = DirectoryWatcher(latency: 0.05) { paths in
        lock.lock(); seen.formUnion(paths); lock.unlock()
        changed.signal()
    }
    w.watch([a])
    Thread.sleep(forTimeInterval: 0.3) // let the stream start
    tmp.file("b/ignored.txt")
    tmp.file("a/new.txt")
    #expect(changed.wait(timeout: .now() + 5) == .success)
    lock.lock(); let snapshot = seen; lock.unlock()
    #expect(snapshot == [DirectoryWatcher.normalize(a.path)])
    #expect(!snapshot.contains(DirectoryWatcher.normalize(b.path)))
    w.stop()
}

@Test func normalizesPaths() {
    #expect(DirectoryWatcher.normalize("/tmp/") == DirectoryWatcher.normalize("/private/tmp"))
}
