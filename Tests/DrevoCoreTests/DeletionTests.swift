import Foundation
import Testing
@testable import DrevoCore

/// Delete Immediately as a background job: entry by entry, with progress and Stop.
@Suite struct DeletionTests {
    let tmp = TempDir()
    var fm: FileManager { .default }
    func exists(_ p: String) -> Bool { FileIdentity.exists(tmp.url.appendingPathComponent(p)) }

    @Test func deletesFilesAndWholeTrees() {
        let a = tmp.file("a.txt")
        let d = tmp.dir("D")
        tmp.file("D/x.txt")
        tmp.file("D/sub/deep/y.txt")
        let r = Deletion([a, d]).run()
        #expect(r.errors.isEmpty)
        #expect(!r.cancelled)
        #expect(!exists("a.txt"))
        #expect(!exists("D"))
    }

    @Test func aLinkToAFolderIsRemovedWithoutItsTarget() throws {
        tmp.file("Target/keep.txt")
        let link = tmp.url.appendingPathComponent("L")
        try fm.createSymbolicLink(at: link, withDestinationURL: tmp.url.appendingPathComponent("Target"))
        let r = Deletion([link]).run()
        #expect(r.errors.isEmpty)
        #expect(!exists("L"))
        #expect(exists("Target/keep.txt"))
    }

    @Test func progressCountsEveryEntry() {
        let d = tmp.dir("D")
        for i in 0..<5 { tmp.file("D/f\(i).txt") }
        let deletion = Deletion([d, tmp.file("a.txt")])
        var updates: [TransferProgress] = []
        deletion.onProgress = { updates.append($0) }
        _ = deletion.run()
        #expect(updates.first?.totalItems == 7, "the folder, its five files and a.txt")
        #expect(updates.first?.completedItems == 0)
        #expect(updates.last?.completedItems == 7)
        #expect(updates.last?.fraction == 1)
        #expect(deletion.title == "Deleting 2 items")
        #expect(Deletion([d]).title == "Deleting “D”")
    }

    /// Stop leaves what wasn't deleted yet in place and is not an error.
    @Test func stopKeepsTheRestAndReportsNoError() {
        let a = tmp.file("a.txt")
        let b = tmp.dir("B")
        tmp.file("B/x.txt")
        let c = tmp.file("c.txt")
        let deletion = Deletion([a, b, c])
        deletion.onProgress = { p in if p.currentName == "B" { deletion.cancel() } }
        let r = deletion.run()
        #expect(r.cancelled)
        #expect(r.errors.isEmpty)
        #expect(!exists("a.txt"), "deleted before Stop")
        #expect(exists("B/x.txt"))
        #expect(exists("c.txt"))
    }

    @Test func stoppedBeforeItStartsDeletesNothing() {
        let d = tmp.dir("D")
        tmp.file("D/x.txt")
        let deletion = Deletion([d])
        deletion.cancel()
        #expect(deletion.run().cancelled)
        #expect(exists("D/x.txt"))
    }

    /// One item that can't be deleted doesn't keep the others.
    @Test func anUndeletableItemIsReportedAndTheRestGoOn() throws {
        let locked = tmp.dir("Locked")
        tmp.file("Locked/x.txt")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let b = tmp.file("b.txt")
        let r = Deletion([locked, b, tmp.url.appendingPathComponent("missing.txt")]).run()
        #expect(r.errors.count == 2, "the locked folder and the missing file")
        #expect(!r.cancelled)
        #expect(exists("Locked/x.txt"))
        #expect(!exists("b.txt"))
    }
}
