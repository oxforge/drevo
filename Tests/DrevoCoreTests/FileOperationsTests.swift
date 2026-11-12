import Foundation
import Testing
@testable import DrevoCore

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

    @Test func failedAliasKeepsEarlierAliasesUndoable() throws {
        let a = tmp.file("a.txt")
        let missing = tmp.url.appendingPathComponent("missing.txt")
        do {
            _ = try ops.makeAlias([a, missing])
            Issue.record("expected a partial failure")
        } catch let partial as PartialFailure {
            #expect(exists("a.txt alias"), "the first alias was made")
            #expect(partial.undo == .created([tmp.url.appendingPathComponent("a.txt alias")]))
            _ = try ops.undo(partial.undo)
            #expect(!exists("a.txt alias"))
        }
        // Nothing made before the failure: a plain error, nothing to undo.
        do {
            _ = try ops.makeAlias([missing])
            Issue.record("expected an error")
        } catch {
            #expect(!(error is PartialFailure))
        }
    }

    @Test func aliasesOfTheSameItemGetDistinctNames() throws {
        let a = tmp.file("a.txt")
        let (made, _) = try ops.makeAlias([a, a])
        #expect(made.map(\.lastPathComponent) == ["a.txt alias", "a.txt alias 2"])
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
        #expect(!a.isInside(URL(fileURLWithPath: "/x/y/z")))
    }

    /// The physical path of an existing item (no symlinks, e.g. /private/var for /var).
    func physical(_ url: URL) -> String {
        let p = realpath(url.path, nil)!
        defer { free(p) }
        return String(cString: p)
    }

    @Test func insideIsDecidedByIdentityNotByPathText() throws {
        let docs = tmp.dir("Docs")
        let sub = tmp.dir("Docs/sub")
        let sibling = tmp.dir("Docs2")
        #expect(sub.isInside(docs))
        #expect(docs.isInside(docs))
        #expect(!docs.isInside(sub))
        #expect(!sibling.isInside(docs))
        #expect(sub.isInside(URL(fileURLWithPath: "/")))

        // The same folders through other spellings of their path.
        #expect(sub.isInside(URL(fileURLWithPath: physical(docs))))
        #expect(URL(fileURLWithPath: physical(sub)).isInside(docs))
        #expect(tmp.url.appendingPathComponent("Docs/./sub/../sub").isInside(docs))
        let viaDataVolume = URL(fileURLWithPath: "/System/Volumes/Data" + physical(sub))
        if FileIdentity.exists(viaDataVolume) {
            #expect(viaDataVolume.isInside(docs))
            #expect(sub.isInside(URL(fileURLWithPath: "/System/Volumes/Data" + physical(docs))))
        }

        // Through a link in the receiver's path: resolved, so it is inside the real folder.
        let link = tmp.url.appendingPathComponent("L")
        try fm.createSymbolicLink(at: link, withDestinationURL: docs)
        #expect(link.appendingPathComponent("sub").isInside(docs))
        #expect(link.isInside(docs), "a link used as the receiver stands for the folder it points to")
        // `other` is not followed: the link itself contains nothing.
        #expect(!sub.isInside(link))
        #expect(!docs.isInside(link))

        // Letter case names the same folder exactly when the volume says so.
        let lower = tmp.url.appendingPathComponent("docs")
        let caseInsensitiveVolume = FileIdentity.exists(lower)
        #expect(sub.isInside(lower) == caseInsensitiveVolume)
        #expect(FileIdentity.sameItem(docs, lower) == caseInsensitiveVolume)
    }

    /// A destination typed by hand may not exist yet: it is inside whatever holds its
    /// nearest existing ancestor.
    @Test func insideForAPathThatDoesNotExistYet() throws {
        let d = tmp.dir("D")
        #expect(d.appendingPathComponent("new/deeper").isInside(d))
        #expect(d.appendingPathComponent("new").isInside(tmp.url))
        #expect(!tmp.url.appendingPathComponent("elsewhere/new").isInside(d))
        let link = tmp.url.appendingPathComponent("L")
        try fm.createSymbolicLink(at: link, withDestinationURL: d)
        #expect(link.appendingPathComponent("new").isInside(d), "the existing part is still resolved")
    }

    @Test func sameItemComparesIdentities() throws {
        let d = tmp.dir("D")
        let other = tmp.dir("E")
        let link = tmp.url.appendingPathComponent("L")
        try fm.createSymbolicLink(at: link, withDestinationURL: d)
        #expect(FileIdentity.sameItem(d, d))
        #expect(FileIdentity.sameItem(d, URL(fileURLWithPath: physical(d))), "/var/… and /private/var/…")
        #expect(FileIdentity.sameItem(d, tmp.url.appendingPathComponent("E/../D")))
        #expect(!FileIdentity.sameItem(d, other))
        #expect(FileIdentity.sameItem(link, d), "links are followed by default")
        #expect(!FileIdentity.sameItem(link, d, followLinks: false))
        #expect(FileIdentity.sameItem(link, link, followLinks: false))
        // Nothing on disk to compare: the standardized paths decide.
        let missing = tmp.url.appendingPathComponent("missing")
        #expect(FileIdentity.sameItem(missing, tmp.url.appendingPathComponent("D/../missing")))
        #expect(!FileIdentity.sameItem(missing, d))
        #expect(!FileIdentity.sameItem(missing, tmp.url.appendingPathComponent("missing2")))
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

    /// Every item that was dealt with counts as done, whether it was copied, skipped or
    /// refused, so the progress bar reaches the end.
    @Test func refusedAndSkippedItemsCountInProgress() {
        // Refused: a folder into itself.
        let d = tmp.dir("D")
        tmp.file("D/x.txt", "XXXX")
        let a = tmp.file("a.txt", "AA")
        let (intoItself, updates, _) = transfer(.copy, [d, a], to: tmp.dir("D/inner"))
        #expect(intoItself.errors.count == 1)
        #expect(updates.last?.totalItems == 2)
        #expect(updates.last?.completedItems == 2)
        #expect(updates.last?.fraction == 1)

        // Refused: Replace would trash the folder that holds the source.
        tmp.file("p/photos/photos/img.jpg", "I")
        let b = tmp.file("src/b.txt", "B")
        let (contains, updates2, _) = transfer(.copy, [tmp.url.appendingPathComponent("p/photos/photos"), b],
                                               to: tmp.url.appendingPathComponent("p"), decide: ConflictDecision(.replace))
        #expect(contains.errors.count == 1)
        #expect(updates2.last?.completedItems == 2)
        #expect(updates2.last?.fraction == 1)

        // Skipped: a move into the folder the item is already in, and a conflict.
        tmp.file("dest/b.txt", "old")
        let (skipped, updates3, _) = transfer(.move, [a, b], to: tmp.url, decide: ConflictDecision(.skip))
        #expect(skipped.skipped == [a])
        let (conflict, updates4, _) = transfer(.copy, [b], to: tmp.url.appendingPathComponent("dest"), decide: ConflictDecision(.skip))
        #expect(conflict.skipped == [b])
        for last in [updates3.last, updates4.last] {
            #expect(last?.completedItems == last?.totalItems)
            #expect(last?.fraction == 1)
        }
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
