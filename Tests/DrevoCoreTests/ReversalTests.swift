import Foundation
import Testing
@testable import DrevoCore

/// A trash that asks for Stop after it has taken `limit` items.
private final class StoppingTrash: Trashing, @unchecked Sendable {
    let folder: FolderTrash
    let limit: Int
    var taken = 0
    var stop: () -> Void = {}

    init(folder: URL, limit: Int) {
        self.folder = FolderTrash(folder: folder)
        self.limit = limit
    }

    func trash(_ url: URL) throws -> URL {
        let result = try folder.trash(url)
        taken += 1
        if taken == limit { stop() }
        return result
    }
}

/// Undo and redo as a background job: progress, Stop, and moving back across volumes as
/// a copy that can be stopped. `volumeOf` makes "src" look like another disk.
@Suite struct ReversalTests {
    let tmp = TempDir()
    var trashDir: URL { tmp.url.appendingPathComponent(".TestTrash") }
    var fm: FileManager { .default }
    func url(_ p: String) -> URL { tmp.url.appendingPathComponent(p) }
    func exists(_ p: String) -> Bool { FileIdentity.exists(url(p)) }
    func read(_ p: String) -> String? { try? String(contentsOf: url(p), encoding: .utf8) }
    func children(_ p: String) -> [String] { ((try? fm.contentsOfDirectory(atPath: url(p).path)) ?? []).sorted() }

    func reversal(_ record: UndoRecord, crossVolume: Bool = false) -> Reversal {
        let r = Reversal(record, trash: FolderTrash(folder: trashDir))
        if crossVolume {
            let sourceDisk = url("src").path
            r.volumeOf = { AnyHashable($0.path.hasPrefix(sourceDisk) ? "source disk" : "destination disk") }
        }
        return r
    }

    /// Moves `names` from "src" to "dest" by renaming; returns the move's undo record.
    func moved(_ names: [String]) throws -> UndoRecord {
        tmp.dir("dest")
        return .moved(try names.map { name in
            try fm.moveItem(at: url("src/\(name)"), to: url("dest/\(name)"))
            return MovedItem(from: url("src/\(name)"), to: url("dest/\(name)"))
        })
    }

    @Test func aFinishedReversalReturnsTheRedoRecord() throws {
        tmp.file("src/a.txt", "A")
        let r = reversal(try moved(["a.txt"])).run()
        #expect(r.error == nil)
        #expect(!r.cancelled)
        #expect(read("src/a.txt") == "A")
        #expect(r.redo == .moved([MovedItem(from: url("dest/a.txt"), to: url("src/a.txt"))]), "the move back, to be undone in turn")
    }

    @Test func movingBackAcrossVolumesCopiesThenRemovesAndReportsBytes() throws {
        tmp.file("src/D/x.txt", "XXXX")
        tmp.file("src/D/sub/y.txt", "YY")
        let record = try moved(["D"])
        let before = try #require(FileIdentity.of(url("dest/D/x.txt"), followLinks: false))
        let r = reversal(record, crossVolume: true)
        var updates: [TransferProgress] = []
        r.onProgress = { updates.append($0) }
        let result = r.run()

        #expect(result.error == nil)
        #expect(read("src/D/x.txt") == "XXXX")
        #expect(read("src/D/sub/y.txt") == "YY")
        #expect(!exists("dest/D"), "the copy's source is removed")
        #expect(FileIdentity.of(url("src/D/x.txt"), followLinks: false) != before, "copied, not renamed")
        #expect(updates.first?.totalBytes == 6)
        #expect(updates.first?.totalItems == 1)
        #expect(updates.last?.completedBytes == 6)
        #expect(updates.last?.completedItems == 1)

        // Redo moves it again, also across the "volumes".
        let again = reversal(try #require(result.redo), crossVolume: true).run()
        #expect(again.error == nil)
        #expect(read("dest/D/x.txt") == "XXXX")
        #expect(!exists("src/D"))
    }

    /// A rename would fail on a taken name; the copy must not merge into it instead.
    @Test func movingBackAcrossVolumesNeverOverwrites() throws {
        tmp.file("src/D/x.txt", "mine")
        let record = try moved(["D"])
        tmp.file("src/D/other.txt", "squatter")
        let result = reversal(record, crossVolume: true).run()
        #expect(result.error != nil)
        #expect(result.redo == nil)
        #expect(children("src/D") == ["other.txt"], "nothing was merged into the folder in the way")
        #expect(read("dest/D/x.txt") == "mine")
    }

    @Test func stopDuringACopyBackLeavesTheItemWhereItWas() throws {
        try fm.createDirectory(at: url("src"), withIntermediateDirectories: true)
        try Data(count: 64 * 1024 * 1024).write(to: url("src/big.bin"))
        tmp.file("src/small.txt", "s")
        let r = reversal(try moved(["small.txt", "big.bin"]), crossVolume: true)
        r.allowClone = false
        r.onProgress = { p in if p.completedBytes > 0 { r.cancel() } }
        let result = r.run()

        #expect(result.cancelled)
        #expect(result.error == nil, "Stop is not an error")
        #expect(result.redo == nil, "nothing was moved back")
        #expect(children("src") == [], "nothing half-copied")
        let size = try fm.attributesOfItem(atPath: url("dest/big.bin").path)[.size] as? Int
        #expect(size == 64 * 1024 * 1024)
        #expect(read("dest/small.txt") == "s")
    }

    /// What was reversed before Stop stays reversed, and the redo record covers just that.
    @Test func stopBetweenItemsKeepsTheReversedPartRedoable() throws {
        let made = ["a.txt", "b.txt", "c.txt"].map { tmp.file($0) }
        let trash = StoppingTrash(folder: trashDir, limit: 2)
        let r = Reversal(.created(made), trash: trash)
        trash.stop = { r.cancel() }
        let result = r.run()

        #expect(result.cancelled)
        #expect(result.error == nil)
        #expect(!exists("a.txt"))
        #expect(!exists("b.txt"))
        #expect(exists("c.txt"), "not reached before Stop")
        guard case .trashed(let items)? = result.redo else { Issue.record("expected a .trashed redo"); return }
        #expect(items.map(\.original.lastPathComponent) == ["a.txt", "b.txt"])

        let redo = reversal(try #require(result.redo)).run()
        #expect(redo.error == nil)
        #expect(exists("a.txt"))
        #expect(exists("b.txt"))
    }

    @Test func stopInsideAGroupKeepsTheStepsAlreadyReversed() throws {
        let renamed = tmp.file("new.txt")
        let made = ["a.txt", "b.txt"].map { tmp.file($0) }
        // Undone last step first: the two created items, then the rename.
        let record = UndoRecord.group([.renamed(from: url("old.txt"), to: renamed), .created(made)])
        let trash = StoppingTrash(folder: trashDir, limit: 2)
        let r = Reversal(record, trash: trash)
        trash.stop = { r.cancel() }
        let result = r.run()

        #expect(result.cancelled)
        #expect(!exists("a.txt"))
        #expect(!exists("b.txt"))
        #expect(exists("new.txt"), "the rename was not undone")
        guard case .group(let steps)? = result.redo else { Issue.record("expected a group"); return }
        #expect(steps.count == 1)
    }

    @Test func aFailureIsReportedWithWhatWasReversed() throws {
        tmp.file("src/a.txt", "A")
        tmp.file("src/b.txt", "B")
        let record = try moved(["a.txt", "b.txt"])
        tmp.file("src/a.txt", "squatter") // a.txt can't go back; b.txt (undone first) can
        let result = reversal(record).run()
        #expect(result.error != nil)
        #expect(!result.cancelled)
        #expect(read("src/b.txt") == "B")
        #expect(result.redo == .moved([MovedItem(from: url("dest/b.txt"), to: url("src/b.txt"))]))
    }

    @Test func progressCountsTheItemsOfEveryStep() {
        let made = ["a.txt", "b.txt"].map { tmp.file($0) }
        tmp.file("new.txt")
        let r = reversal(.group([.renamed(from: url("old.txt"), to: url("new.txt")), .created(made)]))
        var updates: [TransferProgress] = []
        r.onProgress = { updates.append($0) }
        _ = r.run()
        #expect(updates.first?.totalItems == 3)
        #expect(updates.first?.totalBytes == 0, "nothing is copied, so items are counted")
        #expect(updates.last?.completedItems == 3)
    }
}
