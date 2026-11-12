import Foundation
import Testing
@testable import DrevoCore

/// Scenarios from the code review: each one lost or misplaced data before the fix.
@Suite struct ReviewRegressionTests {
    let tmp = TempDir()
    var trashDir: URL { tmp.url.appendingPathComponent(".TestTrash") }
    var fm: FileManager { .default }
    func exists(_ p: String) -> Bool { FileIdentity.exists(tmp.url.appendingPathComponent(p)) }
    func read(_ p: String) -> String? { try? String(contentsOf: tmp.url.appendingPathComponent(p), encoding: .utf8) }

    func run(_ kind: TransferKind, _ sources: [URL], to dest: URL, decide: ConflictAction = .replace) -> (TransferResult, [Conflict]) {
        let t = Transfer(kind: kind, sources: sources, destination: dest)
        t.trash = FolderTrash(folder: trashDir)
        var conflicts: [Conflict] = []
        t.resolveConflict = { conflicts.append($0); return ConflictDecision(decide) }
        return (t.run(), conflicts)
    }

    @Test func sameFolderThroughSymlinkIsNotAConflict() throws {
        let d = tmp.dir("D")
        let a = tmp.file("D/a.txt", "A")
        let link = tmp.url.appendingPathComponent("L")
        try fm.createSymbolicLink(at: link, withDestinationURL: d)
        let (copy, conflicts) = run(.copy, [a], to: link)
        #expect(conflicts.isEmpty, "the source must never be offered as the item to replace")
        #expect(copy.outputs.map(\.lastPathComponent) == ["a copy.txt"])
        #expect(read("D/a.txt") == "A")
        let (move, _) = run(.move, [a], to: link)
        #expect(move.skipped == [a])
        #expect(read("D/a.txt") == "A")
        #expect(!exists(".TestTrash/a.txt"))
    }

    @Test func sameFolderThroughDifferentCaseIsNotAConflict() {
        tmp.dir("Photos")
        let a = tmp.file("Photos/a.txt", "A")
        let lower = tmp.url.appendingPathComponent("photos")
        let (move, conflicts) = run(.move, [a], to: lower)
        #expect(conflicts.isEmpty)
        #expect(read("Photos/a.txt") == "A")
        #expect(move.skipped.count == 1)
    }

    @Test func replaceRefusesToTrashAFolderContainingTheSource() {
        tmp.dir("p/photos/photos")
        tmp.file("p/photos/photos/img.jpg", "I")
        let (r, _) = run(.move, [tmp.url.appendingPathComponent("p/photos/photos")], to: tmp.url.appendingPathComponent("p"))
        #expect(r.errors.count == 1)
        #expect(read("p/photos/photos/img.jpg") == "I")
        #expect(!exists(".TestTrash/photos"))
    }

    @Test func replaceKeepsTheOldItemWhenTheCopyFails() throws {
        let src = tmp.file("src/a.txt", "new")
        tmp.file("dst/a.txt", "old")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: src.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: src.path) }
        let (r, _) = run(.copy, [src], to: tmp.url.appendingPathComponent("dst"))
        #expect(r.errors.count == 1)
        #expect(read("dst/a.txt") == "old", "the existing item stays until the new one is complete")
        #expect(!exists(".TestTrash/a.txt"))
        let leftovers = try fm.contentsOfDirectory(atPath: tmp.url.appendingPathComponent("dst").path)
        #expect(leftovers == ["a.txt"], "no staged temporary item left behind")
    }

    @Test func replaceStillWorksAndUndoes() throws {
        let src = tmp.file("src/a.txt", "new")
        tmp.file("dst/a.txt", "old")
        let (r, _) = run(.move, [src], to: tmp.url.appendingPathComponent("dst"))
        #expect(read("dst/a.txt") == "new")
        #expect(!exists("src/a.txt"))
        _ = try FileOperations(trash: FolderTrash(folder: trashDir)).undo(try #require(r.undo))
        #expect(read("dst/a.txt") == "old")
        #expect(read("src/a.txt") == "new")
    }

    /// The staged item's temporary name must not grow with the original name (255-byte limit).
    @Test func replaceWorksForAVeryLongName() throws {
        let name = String(repeating: "n", count: 246) + ".txt" // 250 bytes
        let src = tmp.file("src/\(name)", "new")
        tmp.file("dst/\(name)", "old")
        let (r, _) = run(.copy, [src], to: tmp.url.appendingPathComponent("dst"))
        #expect(r.errors == [])
        #expect(read("dst/\(name)") == "new")
        #expect(read(".TestTrash/\(name)") == "old")
        #expect(try fm.contentsOfDirectory(atPath: tmp.url.appendingPathComponent("dst").path) == [name])
    }

    @Test func copyingASymlinkIntoItsTargetIsAllowed() throws {
        let d = tmp.dir("D")
        let sub = tmp.dir("D/sub")
        let link = tmp.url.appendingPathComponent("L")
        try fm.createSymbolicLink(at: link, withDestinationURL: d)
        let (r, _) = run(.copy, [link], to: sub)
        #expect(r.errors.isEmpty)
        let copied = sub.appendingPathComponent("L")
        #expect((try? copied.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true)
        #expect(sub.isInside(d), "a real folder is still inside its parent")
    }

    @Test func failedDuplicateLeavesNothingBehind() throws {
        let a = tmp.file("a.txt", "A")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: a.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: a.path) }
        let ops = FileOperations(trash: FolderTrash(folder: trashDir))
        #expect(throws: (any Error).self) { try ops.duplicate([a]) }
        #expect(!exists("a copy.txt"))
    }

    @Test func partialUndoKeepsWhatWasReversed() throws {
        let a = tmp.file("src/a.txt", "A")
        let b = tmp.file("src/b.txt", "B")
        let (r, _) = run(.move, [a, b], to: tmp.dir("dst"))
        // Something new now sits where a.txt came from, so its move-back fails.
        tmp.file("src/a.txt", "squatter")
        let ops = FileOperations(trash: FolderTrash(folder: trashDir))
        do {
            _ = try ops.undo(try #require(r.undo))
            Issue.record("expected a partial failure")
        } catch let partial as PartialFailure {
            #expect(read("src/b.txt") == "B", "b was moved back")
            guard case .moved(let redo) = partial.undo else { Issue.record("expected .moved redo"); return }
            #expect(redo.map(\.to.lastPathComponent) == ["b.txt"])
        }
    }
}
