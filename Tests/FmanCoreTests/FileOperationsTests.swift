import Foundation
import Testing
@testable import FmanCore

@Suite struct FileOperationsTests {
    let tmp = TempDir()
    var ops: FileOperations { FileOperations(trash: FolderTrash(folder: tmp.url.appendingPathComponent(".TestTrash"))) }
    var fm: FileManager { .default }

    func exists(_ path: String) -> Bool { fm.fileExists(atPath: tmp.url.appendingPathComponent(path).path) }
    func read(_ path: String) -> String? { try? String(contentsOf: tmp.url.appendingPathComponent(path), encoding: .utf8) }

    @Test func newFolderAndUndoRedo() throws {
        let (url, record) = try ops.makeFolder(in: tmp.url)
        #expect(url.lastPathComponent == "untitled folder")
        let (url2, _) = try ops.makeFolder(in: tmp.url)
        #expect(url2.lastPathComponent == "untitled folder 2")
        let redo = try ops.undo(record)
        #expect(!exists("untitled folder"))
        _ = try ops.undo(redo)
        #expect(exists("untitled folder"))
    }

    @Test func newFile() throws {
        let (url, _) = try ops.makeFile(in: tmp.url)
        #expect(url.lastPathComponent == "untitled.txt")
        #expect(try ops.makeFile(in: tmp.url).0.lastPathComponent == "untitled 2.txt")
    }

    @Test func renameValidatesAndUndoes() throws {
        let a = tmp.file("a.txt", "A")
        tmp.file("b.txt", "B")
        #expect(throws: FileOperationError.nameTaken("b.txt")) { try ops.rename(a, to: "b.txt") }
        #expect(throws: FileOperationError.self) { try ops.rename(a, to: "x/y") }
        #expect(throws: FileOperationError.self) { try ops.rename(a, to: "  ") }
        let (c, record) = try ops.rename(a, to: " c.txt ")
        #expect(c.lastPathComponent == "c.txt")
        _ = try ops.undo(try #require(record))
        #expect(read("a.txt") == "A")
        // Case-only rename is allowed on a case-insensitive volume.
        let (upper, _) = try ops.rename(a, to: "A.txt")
        #expect(upper.lastPathComponent == "A.txt")
        #expect(try ops.rename(upper, to: "A.txt").1 == nil)
    }

    @Test func trashAndPutBack() throws {
        let a = tmp.file("a.txt", "A")
        let record = try ops.moveToTrash([a])
        #expect(!exists("a.txt"))
        let redo = try ops.undo(record)
        #expect(read("a.txt") == "A")
        #expect(redo == .created([a]))
    }

    @Test func putBackDoesNotClobber() throws {
        let a = tmp.file("a.txt", "old")
        let record = try ops.moveToTrash([a])
        tmp.file("a.txt", "new")
        _ = try ops.undo(record)
        #expect(read("a.txt") == "new")
        #expect(read("a 2.txt") == "old")
    }

    @Test func duplicateUsesFinderNames() throws {
        let a = tmp.file("a.txt")
        let d = tmp.dir("Folder")
        tmp.file("Folder/inner.txt", "in")
        let (made, record) = try ops.duplicate([a, d])
        #expect(made.map(\.lastPathComponent) == ["a copy.txt", "Folder copy"])
        #expect(read("Folder copy/inner.txt") == "in")
        _ = try ops.undo(record)
        #expect(!exists("a copy.txt"))
    }

    @Test func aliasResolvesToTarget() throws {
        let d = tmp.dir("Target")
        let (made, _) = try ops.makeAlias([d])
        #expect(made.first?.lastPathComponent == "Target alias")
        let resolved = try URL(resolvingAliasFileAt: made[0])
        #expect(resolved.standardizedFileURL.resolvingSymlinksInPath().path == d.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    @Test func deleteImmediately() throws {
        let a = tmp.file("a.txt")
        try ops.deleteImmediately([a])
        #expect(!exists("a.txt"))
    }

    @Test func insideCheck() {
        let a = URL(fileURLWithPath: "/x/y")
        #expect(URL(fileURLWithPath: "/x/y/z").isInside(a))
        #expect(a.isInside(a))
        #expect(!URL(fileURLWithPath: "/x/yz").isInside(a))
    }
}

@Suite struct TransferTests {
    let tmp = TempDir()
    var trash: FolderTrash { FolderTrash(folder: tmp.url.appendingPathComponent(".TestTrash")) }
    var fm: FileManager { .default }
    func read(_ path: String) -> String? { try? String(contentsOf: tmp.url.appendingPathComponent(path), encoding: .utf8) }
    func exists(_ path: String) -> Bool { fm.fileExists(atPath: tmp.url.appendingPathComponent(path).path) }

    func transfer(_ kind: TransferKind, _ sources: [URL], to dest: URL, decide: ConflictDecision? = nil) -> (TransferResult, [TransferProgress], [Conflict]) {
        let t = Transfer(kind: kind, sources: sources, destination: dest)
        t.trash = trash
        var updates: [TransferProgress] = []
        var conflicts: [Conflict] = []
        t.onProgress = { updates.append($0) }
        t.resolveConflict = { c in conflicts.append(c); return decide ?? ConflictDecision(.stop) }
        return (t.run(), updates, conflicts)
    }

    @Test func copiesFilesAndFoldersWithProgress() throws {
        let a = tmp.file("src/a.txt", "AAAA")
        let d = tmp.dir("src/D")
        tmp.file("src/D/x.txt", "XX")
        let dest = tmp.dir("dest")
        let (r, updates, _) = transfer(.copy, [a, d], to: dest)
        #expect(r.errors.isEmpty)
        #expect(read("dest/a.txt") == "AAAA")
        #expect(read("dest/D/x.txt") == "XX")
        #expect(read("src/a.txt") == "AAAA", "copy keeps the source")
        #expect(updates.last?.completedItems == 2)
        #expect(updates.last?.fraction == 1)
        guard case .created(let urls) = r.undo else { Issue.record("expected .created"); return }
        #expect(urls.map(\.lastPathComponent) == ["a.txt", "D"])
    }

    @Test func copyPreservesModificationDate() throws {
        let a = tmp.file("src/a.txt", "A")
        let date = Date(timeIntervalSince1970: 1_000_000_000)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: a.path)
        let dest = tmp.dir("dest")
        _ = transfer(.copy, [a], to: dest)
        let copied = try fm.attributesOfItem(atPath: dest.appendingPathComponent("a.txt").path)[.modificationDate] as? Date
        #expect(copied == date)
    }

    @Test func copyIntoSameFolderMakesCopyName() {
        let a = tmp.file("a.txt", "A")
        let (r, _, conflicts) = transfer(.copy, [a], to: tmp.url)
        #expect(conflicts.isEmpty)
        #expect(r.outputs.map(\.lastPathComponent) == ["a copy.txt"])
    }

    @Test func conflictKeepBoth() {
        let a = tmp.file("src/a.txt", "new")
        tmp.file("dest/a.txt", "old")
        let (r, _, conflicts) = transfer(.copy, [a], to: tmp.url.appendingPathComponent("dest"), decide: ConflictDecision(.keepBoth))
        #expect(conflicts.count == 1)
        #expect(r.outputs.map(\.lastPathComponent) == ["a 2.txt"])
        #expect(read("dest/a.txt") == "old")
        #expect(read("dest/a 2.txt") == "new")
    }

    @Test func conflictReplaceTrashesOldAndUndoRestoresIt() throws {
        let a = tmp.file("src/a.txt", "new")
        tmp.file("dest/a.txt", "old")
        let (r, _, _) = transfer(.copy, [a], to: tmp.url.appendingPathComponent("dest"), decide: ConflictDecision(.replace))
        #expect(read("dest/a.txt") == "new")
        let ops = FileOperations(trash: trash)
        _ = try ops.undo(try #require(r.undo))
        #expect(read("dest/a.txt") == "old")
    }

    @Test func conflictSkipAndStop() {
        let a = tmp.file("src/a.txt", "new")
        let b = tmp.file("src/b.txt", "b")
        tmp.file("dest/a.txt", "old")
        let dest = tmp.url.appendingPathComponent("dest")
        let (skip, _, _) = transfer(.copy, [a, b], to: dest, decide: ConflictDecision(.skip))
        #expect(skip.skipped == [a])
        #expect(read("dest/b.txt") == "b")
        try? fm.removeItem(at: dest.appendingPathComponent("b.txt"))
        let (stop, _, _) = transfer(.copy, [a, b], to: dest, decide: ConflictDecision(.stop))
        #expect(stop.cancelled)
        #expect(!exists("dest/b.txt"), "stop ends the whole transfer")
    }

    @Test func applyToAllAsksOnce() {
        let a = tmp.file("src/a.txt", "1")
        let b = tmp.file("src/b.txt", "2")
        tmp.file("dest/a.txt", "x")
        tmp.file("dest/b.txt", "y")
        let (r, _, conflicts) = transfer(.copy, [a, b], to: tmp.url.appendingPathComponent("dest"), decide: ConflictDecision(.keepBoth, applyToAll: true))
        #expect(conflicts.count == 1)
        #expect(conflicts.first?.remaining == 1)
        #expect(r.outputs.map(\.lastPathComponent) == ["a 2.txt", "b 2.txt"])
    }

    @Test func refusesCopyIntoItself() {
        let d = tmp.dir("D")
        let inner = tmp.dir("D/inner")
        let (r, _, _) = transfer(.copy, [d], to: inner)
        #expect(r.errors.count == 1)
        #expect(r.outputs.isEmpty)
    }

    @Test func moveSameVolumeAndUndo() throws {
        let a = tmp.file("src/a.txt", "A")
        let dest = tmp.dir("dest")
        let (r, _, _) = transfer(.move, [a], to: dest)
        #expect(!exists("src/a.txt"))
        #expect(read("dest/a.txt") == "A")
        let ops = FileOperations(trash: trash)
        let redo = try ops.undo(try #require(r.undo))
        #expect(read("src/a.txt") == "A")
        _ = try ops.undo(redo)
        #expect(read("dest/a.txt") == "A")
    }

    @Test func moveIntoOwnFolderIsSkipped() {
        let a = tmp.file("a.txt", "A")
        let (r, _, _) = transfer(.move, [a], to: tmp.url)
        #expect(r.skipped == [a])
        #expect(r.undo == nil)
    }

    @Test func cancelStopsAndCleansUp() throws {
        let big = tmp.url.appendingPathComponent("big.bin")
        try Data(count: 64 * 1024 * 1024).write(to: big)
        let dest = tmp.dir("dest")
        let t = Transfer(kind: .copy, sources: [big], destination: dest)
        t.allowClone = false
        t.onProgress = { p in if p.completedBytes > 0 { t.cancel() } }
        let r = t.run()
        #expect(r.cancelled)
        #expect(!exists("dest/big.bin"), "partial copy removed")
    }

    @Test func dataCopyWithoutCloneReportsBytes() throws {
        let f = tmp.url.appendingPathComponent("f.bin")
        try Data(count: 8 * 1024 * 1024).write(to: f)
        let dest = tmp.dir("dest")
        let t = Transfer(kind: .copy, sources: [f], destination: dest)
        t.allowClone = false
        var maxBytes: Int64 = 0
        t.onProgress = { maxBytes = max(maxBytes, $0.completedBytes) }
        let r = t.run()
        #expect(r.errors.isEmpty)
        #expect(maxBytes == 8 * 1024 * 1024)
    }
}
