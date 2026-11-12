import AppKit
import Testing
@testable import FmanCore
@testable import FmanUI

/// Drop validation runs on every mouse move, so what depends only on the drag is worked
/// out once per drag. These tests pin the answers to the uncached rules.
@MainActor
@Suite(.serialized) struct DragValidationTests {
    let fx = Fixture()
    var src: URL { fx.url.appendingPathComponent("src") }
    var dst: URL { fx.url.appendingPathComponent("dst") }

    /// The drop pane shows dst: row 0 is the folder "Inner", row 1 the file "file.txt".
    init() {
        fx.file("src/a.txt", "A")
        fx.file("src/b.txt", "B")
        fx.dir("src/Sub")
        fx.dir("dst/Inner/Deep")
        fx.file("dst/file.txt", "F")
        try! FileManager.default.createSymbolicLink(at: fx.url.appendingPathComponent("link"), withDestinationURL: dst)
    }

    func window() -> MainWindowController { makeWindow([src, dst]) }

    func dropTarget(_ wc: MainWindowController) -> (NSTableView, NSTableViewDataSource) {
        let list = wc.paneGroup.panes[1].browser as! FileListViewController
        return (list.tableView, list)
    }

    /// The rules as they were before caching, straight from the core helpers.
    func uncached(_ sources: [URL], mask: NSDragOperation, onto dest: URL) -> NSDragOperation {
        guard !sources.isEmpty else { return [] }
        if sources.contains(where: { dest.isInside($0) }) { return [] }
        let kind = DropPolicy.kind(sources: sources, destination: dest, optionKey: mask == .copy,
                                   commandKey: mask == .generic || mask == .move)
        if kind == .move, sources.allSatisfy({ FileIdentity.sameItem($0.deletingLastPathComponent(), dest) }) {
            return []
        }
        return kind == .copy ? .copy : .move
    }

    /// What gets dragged, by name for the failure message.
    var drags: [(String, [URL])] {
        [
            ("one file", [src.appendingPathComponent("a.txt")]),
            ("files and a folder", ["a.txt", "b.txt", "Sub"].map(src.appendingPathComponent)),
            ("the drop folder itself", [dst]),
            ("a folder of the drop folder", [dst.appendingPathComponent("Inner")]),
            ("a file of the drop folder", [dst.appendingPathComponent("file.txt")]),
            ("a folder reached through a symlink", [fx.url.appendingPathComponent("link/Inner")]),
            ("a path in another letter case", [URL(fileURLWithPath: dst.path.uppercased() + "/INNER")]),
            ("items from two folders", [src.appendingPathComponent("a.txt"), dst.appendingPathComponent("file.txt")]),
            ("an ancestor of the drop folder", [fx.url]),
            ("the root folder", [URL(fileURLWithPath: "/")]),
            // On the system volume, the fixture is on the Data volume: a plain drag copies.
            ("a file on another volume", [URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")]),
            ("two volumes", [URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist"), src.appendingPathComponent("a.txt")]),
            ("an item that isn't on disk", [dst.appendingPathComponent("Inner/missing")]),
            ("an item in a folder that isn't on disk", [dst.appendingPathComponent("gone/missing")]),
            ("a link to the drop folder", [fx.url.appendingPathComponent("link")]),
            ("nothing", []),
        ]
    }

    @Test func cachedValidationAnswersLikeTheUncachedRules() {
        let wc = window()
        let (table, ds) = dropTarget(wc)
        let inner = dst.appendingPathComponent("Inner")
        // Proposed drops and the folder each one lands in.
        let drops: [(row: Int, op: NSTableView.DropOperation, dest: URL)] = [
            (0, .on, inner), (1, .on, dst), (-1, .on, dst), (5, .above, dst), (0, .above, dst),
        ]
        let masks: [NSDragOperation] = [[.copy, .move, .link, .generic], .copy, .generic, .move]
        var answers = Set<UInt>()
        for (name, urls) in drags {
            let drag = FakeDrag(urls)
            // Twice over the same drag: the second pass is answered from the cache, and
            // the modifier keys change while the drag is under way.
            for pass in 1...2 {
                for mask in masks {
                    drag.mask = mask
                    for drop in drops {
                        let answer = ds.tableView!(table, validateDrop: drag, proposedRow: drop.row, proposedDropOperation: drop.op)
                        let expected = uncached(urls, mask: mask, onto: drop.dest)
                        #expect(answer == expected, "\(name), mask \(mask.rawValue), row \(drop.row), pass \(pass)")
                        answers.insert(answer.rawValue)
                    }
                }
            }
        }
        // The scenarios really cover refusal, copy and move.
        #expect(answers == [NSDragOperation([]).rawValue, NSDragOperation.copy.rawValue, NSDragOperation.move.rawValue])
    }

    @Test func aDragIsReadFromThePasteboardOnce() {
        let urls = [src.appendingPathComponent("a.txt"), src.appendingPathComponent("b.txt")]
        let drag = FakeDrag(urls)
        let first = FileDragDrop.draggedFiles(drag)
        #expect(first.urls.map(\.lastPathComponent) == ["a.txt", "b.txt"])
        #expect(FileDragDrop.draggedFiles(drag) === first, "the same drag reuses what was worked out")
        // The next drag starts fresh, and going back to an old one doesn't serve stale files.
        let next = FakeDrag([dst.appendingPathComponent("file.txt")])
        let second = FileDragDrop.draggedFiles(next)
        #expect(second !== first)
        #expect(second.urls.map(\.lastPathComponent) == ["file.txt"])
        #expect(FileDragDrop.draggedFiles(drag).urls.map(\.lastPathComponent) == ["a.txt", "b.txt"])
    }

    /// A drag whose pasteboard changes under the same number is read again.
    @Test func aChangedPasteboardIsReadAgain() {
        let drag = FakeDrag([src.appendingPathComponent("a.txt")])
        #expect(FileDragDrop.draggedFiles(drag).urls.map(\.lastPathComponent) == ["a.txt"])
        drag.pasteboard.clearContents()
        drag.pasteboard.writeObjects([src.appendingPathComponent("b.txt")] as [NSURL])
        #expect(FileDragDrop.draggedFiles(drag).urls.map(\.lastPathComponent) == ["b.txt"])
    }

    /// Every move of a big drag over other rows is answered from the first one's work.
    @Test func aLargeDragIsWorkedOutOnceForAllRows() {
        for i in 0..<200 { fx.file("src/many/f\(i).txt") }
        let many = (0..<200).map { src.appendingPathComponent("many/f\($0).txt") }
        let wc = window()
        let (table, ds) = dropTarget(wc)
        let drag = FakeDrag(many)
        #expect(ds.tableView!(table, validateDrop: drag, proposedRow: -1, proposedDropOperation: .on) == .move)
        let files = FileDragDrop.draggedFiles(drag)
        #expect(files.urls.count == 200)
        for row in [0, 1, -1, 0] {
            #expect(ds.tableView!(table, validateDrop: drag, proposedRow: row, proposedDropOperation: .on) == .move)
        }
        #expect(FileDragDrop.draggedFiles(drag) === files)
    }
}
