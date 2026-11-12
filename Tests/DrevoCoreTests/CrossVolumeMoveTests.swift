import Foundation
import Testing
@testable import DrevoCore

/// A trash that always fails, to reach the rollback of a replace.
private struct FailingTrash: Trashing {
    struct Refused: Error {}
    func trash(_ url: URL) throws -> URL { throw Refused() }
}

/// A move between volumes is a copy followed by deleting the source: the one path that
/// deletes user data after copying it. `Transfer.volumeOf` makes "src" and everything else
/// look like two disks, so that path runs inside one temp folder.
@Suite struct CrossVolumeMoveTests {
    let tmp = TempDir()
    var trashDir: URL { tmp.url.appendingPathComponent(".TestTrash") }
    var fm: FileManager { .default }
    var ops: FileOperations { FileOperations(trash: FolderTrash(folder: trashDir)) }
    func url(_ p: String) -> URL { tmp.url.appendingPathComponent(p) }
    func exists(_ p: String) -> Bool { FileIdentity.exists(url(p)) }
    func read(_ p: String) -> String? { try? String(contentsOf: url(p), encoding: .utf8) }
    func children(_ p: String) -> [String] { ((try? fm.contentsOfDirectory(atPath: url(p).path)) ?? []).sorted() }

    func crossVolumeMove(_ sources: [URL], to dest: URL, decide: ConflictAction = .stop) -> Transfer {
        let t = Transfer(kind: .move, sources: sources, destination: dest)
        t.trash = FolderTrash(folder: trashDir)
        let sourceDisk = url("src").path
        t.volumeOf = { AnyHashable($0.path.hasPrefix(sourceDisk) ? "source disk" : "destination disk") }
        t.resolveConflict = { _ in ConflictDecision(decide) }
        return t
    }

    @Test func copiesThenRemovesTheSource() throws {
        let a = tmp.file("src/a.txt", "AAAA")
        let d = tmp.dir("src/D")
        tmp.file("src/D/x.txt", "XX")
        let dest = tmp.dir("dest")
        let original = try #require(FileIdentity.of(a, followLinks: false))
        let t = crossVolumeMove([a, d], to: dest)
        var updates: [TransferProgress] = []
        t.onProgress = { updates.append($0) }
        let r = t.run()

        #expect(r.errors.isEmpty)
        #expect(read("dest/a.txt") == "AAAA")
        #expect(read("dest/D/x.txt") == "XX")
        #expect(!exists("src/a.txt"), "the source is removed after the copy")
        #expect(!exists("src/D"))
        #expect(FileIdentity.of(url("dest/a.txt"), followLinks: false) != original, "copied, not renamed")
        #expect(r.outputs.map(\.lastPathComponent) == ["a.txt", "D"])
        guard case .moved(let items) = r.undo else { Issue.record("expected .moved"); return }
        #expect(items.map(\.from.path) == [a.path, d.path])
        #expect(items.map(\.to.path) == [url("dest/a.txt").path, url("dest/D").path])
        #expect(updates.first?.totalBytes == 6, "a move across volumes counts bytes")
        #expect(updates.last?.completedItems == 2)
        #expect(updates.last?.fraction == 1)
    }

    @Test func cancellingMidCopyKeepsTheSource() throws {
        let big = url("src/big.bin")
        tmp.dir("src")
        try Data(count: 64 * 1024 * 1024).write(to: big)
        let small = tmp.file("src/small.txt", "s")
        let dest = tmp.dir("dest")
        let t = crossVolumeMove([big, small], to: dest)
        t.allowClone = false
        t.onProgress = { p in if p.completedBytes > 0 { t.cancel() } }
        let r = t.run()

        #expect(r.cancelled)
        #expect(r.undo == nil)
        #expect(r.outputs.isEmpty)
        let size = try fm.attributesOfItem(atPath: big.path)[.size] as? Int
        #expect(size == 64 * 1024 * 1024, "the source is untouched")
        #expect(read("src/small.txt") == "s")
        #expect(children("dest") == [], "nothing half-copied at the destination")
    }

    @Test func failedCopyKeepsTheSource() throws {
        let a = tmp.file("src/a.txt", "A")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: a.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: a.path) }
        let r = crossVolumeMove([a], to: tmp.dir("dest")).run()
        #expect(r.errors.count == 1)
        #expect(exists("src/a.txt"))
        #expect(children("dest") == [])
        #expect(r.undo == nil)
    }

    @Test func replaceTrashesTheOldItemAndUndoRestoresEverything() throws {
        let a = tmp.file("src/a.txt", "new")
        tmp.file("dest/a.txt", "old")
        let r = crossVolumeMove([a], to: url("dest"), decide: .replace).run()

        #expect(r.errors.isEmpty)
        #expect(read("dest/a.txt") == "new")
        #expect(!exists("src/a.txt"))
        #expect(read(".TestTrash/a.txt") == "old", "the replaced item goes to the trash")
        #expect(children("dest") == ["a.txt"], "no staged temporary item left behind")
        #expect(r.outputs == [url("dest/a.txt")])

        let redo = try ops.undo(try #require(r.undo))
        #expect(read("dest/a.txt") == "old")
        #expect(read("src/a.txt") == "new")
        _ = try ops.undo(redo)
        #expect(read("dest/a.txt") == "new")
        #expect(!exists("src/a.txt"))
    }

    @Test func replaceThatCannotTrashTheOldItemKeepsBoth() {
        let a = tmp.file("src/a.txt", "new")
        tmp.file("dest/a.txt", "old")
        let t = crossVolumeMove([a], to: url("dest"), decide: .replace)
        t.trash = FailingTrash()
        let r = t.run()
        #expect(r.errors.count == 1)
        #expect(read("src/a.txt") == "new", "the source stays when the replace fails")
        #expect(read("dest/a.txt") == "old")
        #expect(children("dest") == ["a.txt"])
        #expect(r.undo == nil)
        #expect(r.outputs.isEmpty)
    }

    @Test func undoMovesTheItemBackAndRedoMovesItAgain() throws {
        let d = tmp.dir("src/D")
        tmp.file("src/D/x.txt", "XX")
        let r = crossVolumeMove([d], to: tmp.dir("dest")).run()
        #expect(!exists("src/D"))
        let redo = try ops.undo(try #require(r.undo))
        #expect(read("src/D/x.txt") == "XX")
        #expect(!exists("dest/D"))
        _ = try ops.undo(redo)
        #expect(read("dest/D/x.txt") == "XX")
        #expect(!exists("src/D"))
    }

    /// The copy succeeded but the original can't be deleted (read-only disk image, locked
    /// card, no permission on its folder): the item counts as copied.
    @Test func sourceThatCannotBeDeletedCountsAsCopied() throws {
        let a = tmp.file("src/a.txt", "A")
        let b = tmp.file("src/sub/b.txt", "B")
        let dest = tmp.dir("dest")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url("src").path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url("src").path) }
        let r = crossVolumeMove([a, b], to: dest).run()

        #expect(read("dest/a.txt") == "A")
        #expect(read("src/a.txt") == "A", "the original is still there")
        #expect(!exists("src/sub/b.txt"), "an item that can be deleted is still moved")
        #expect(r.outputs == [url("dest/a.txt"), url("dest/b.txt")], "the pane selects the copy too")
        #expect(r.errors.count == 1)
        let message = try #require(r.errors.first)
        #expect(message.contains("a.txt"))
        #expect(message.contains("was copied"))
        #expect(message.contains("original couldn’t be removed"))
        #expect(r.undo == .group([.created([url("dest/a.txt")]), .moved([MovedItem(from: b, to: url("dest/b.txt"))])]))

        // Undo removes the copy and moves the other item back.
        _ = try ops.undo(try #require(r.undo))
        #expect(children("dest") == [])
        #expect(read("src/a.txt") == "A")
        #expect(read("src/sub/b.txt") == "B")
    }

    /// A folder whose contents can be deleted but which itself can't (its parent is
    /// read-only): deleting would empty it before failing on the folder, leaving half an
    /// original next to the only complete copy. Nothing of it may be touched.
    @Test func folderThatCannotBeDeletedKeepsAllItsContents() throws {
        let d = tmp.dir("src/D")
        tmp.file("src/D/x.txt", "XX")
        tmp.file("src/D/sub/y.txt", "YY")
        tmp.dir("src/D/empty")
        let dest = tmp.dir("dest")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url("src").path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url("src").path) }
        let r = crossVolumeMove([d], to: dest).run()

        #expect(children("src/D") == ["empty", "sub", "x.txt"], "the original keeps everything")
        #expect(read("src/D/x.txt") == "XX")
        #expect(read("src/D/sub/y.txt") == "YY")
        #expect(children("dest/D") == ["empty", "sub", "x.txt"], "the copy is complete")
        #expect(read("dest/D/x.txt") == "XX")
        #expect(read("dest/D/sub/y.txt") == "YY")
        #expect(r.outputs.map(\.path) == [url("dest/D").path])
        #expect(r.errors.count == 1)
        let message = try #require(r.errors.first)
        #expect(message.contains("“D” was copied, but the original couldn’t be removed."))
        guard case .created(let made) = r.undo else { Issue.record("expected .created: undo removes the copy only"); return }
        #expect(made.map(\.path) == [url("dest/D").path])

        // Undo removes the copy and nothing else.
        _ = try ops.undo(try #require(r.undo))
        #expect(children("dest") == [])
        #expect(children("src/D") == ["empty", "sub", "x.txt"])
        #expect(read("src/D/sub/y.txt") == "YY")
    }
}

/// The same rollback on the rename path, where the staged item goes back to the source.
@Suite struct SameVolumeReplaceRollbackTests {
    let tmp = TempDir()

    @Test func replaceThatCannotTrashTheOldItemPutsTheSourceBack() throws {
        let a = tmp.file("src/a.txt", "new")
        tmp.file("dest/a.txt", "old")
        let dest = tmp.url.appendingPathComponent("dest")
        let t = Transfer(kind: .move, sources: [a], destination: dest)
        t.trash = FailingTrash()
        t.resolveConflict = { _ in ConflictDecision(.replace) }
        let r = t.run()
        #expect(r.errors.count == 1)
        #expect(try String(contentsOf: a, encoding: .utf8) == "new")
        #expect(try String(contentsOf: dest.appendingPathComponent("a.txt"), encoding: .utf8) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path) == ["a.txt"])
        #expect(r.undo == nil)
    }
}
