import AppKit
import Testing
@testable import FmanCore
@testable import FmanUI

/// Stand-in for a real drag: a private pasteboard with file URLs and a modifier mask.
@MainActor
final class FakeDrag: NSObject, @preconcurrency NSDraggingInfo {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("fman.drag.\(UUID().uuidString)"))
    var mask: NSDragOperation
    /// Like AppKit's: a new number for every drag, the same one for all its events.
    let sequenceNumber: Int
    private static var lastSequenceNumber = 0

    init(_ urls: [URL], mask: NSDragOperation = [.copy, .move, .link, .generic]) {
        self.mask = mask
        Self.lastSequenceNumber += 1
        sequenceNumber = Self.lastSequenceNumber
        super.init()
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { mask }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { sequenceNumber }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

@MainActor
@Suite(.serialized) struct DragDropTests {
    let fx = Fixture()

    init() {
        fx.file("src/a.txt", "A")
        fx.dir("dst/Inner")
    }

    func dropTarget(_ wc: MainWindowController) -> (NSTableView, NSTableViewDataSource) {
        let list = wc.paneGroup.panes[1].browser as! FileListViewController
        return (list.tableView, list)
    }

    @Test func dropOnBackgroundMovesWithinVolume() {
        let wc = makeWindow([fx.url.appendingPathComponent("src"), fx.url.appendingPathComponent("dst")])
        let (table, ds) = dropTarget(wc)
        let drag = FakeDrag([fx.url.appendingPathComponent("src/a.txt")])
        let op = ds.tableView!(table, validateDrop: drag, proposedRow: 5, proposedDropOperation: .above)
        #expect(op == .move)
        #expect(ds.tableView!(table, acceptDrop: drag, row: -1, dropOperation: .on))
        #expect(FileManager.default.fileExists(atPath: fx.url.appendingPathComponent("dst/a.txt").path))
        #expect(!FileManager.default.fileExists(atPath: fx.url.appendingPathComponent("src/a.txt").path))
    }

    @Test func optionDragCopiesOntoFolderRow() {
        let wc = makeWindow([fx.url.appendingPathComponent("src"), fx.url.appendingPathComponent("dst")])
        let (table, ds) = dropTarget(wc)
        let drag = FakeDrag([fx.url.appendingPathComponent("src/a.txt")], mask: .copy)
        let op = ds.tableView!(table, validateDrop: drag, proposedRow: 0, proposedDropOperation: .on)
        #expect(op == .copy)
        #expect(ds.tableView!(table, acceptDrop: drag, row: 0, dropOperation: .on))
        #expect(FileManager.default.fileExists(atPath: fx.url.appendingPathComponent("dst/Inner/a.txt").path))
        #expect(FileManager.default.fileExists(atPath: fx.url.appendingPathComponent("src/a.txt").path))
    }

    @Test func refusesDropIntoItselfAndSameFolderMove() {
        let wc = makeWindow([fx.url, fx.url.appendingPathComponent("dst")])
        let (table, ds) = dropTarget(wc)
        let intoItself = FakeDrag([fx.url.appendingPathComponent("dst")])
        #expect(ds.tableView!(table, validateDrop: intoItself, proposedRow: 0, proposedDropOperation: .on) == [])
        let sameFolder = FakeDrag([fx.url.appendingPathComponent("dst/Inner")])
        #expect(ds.tableView!(table, validateDrop: sameFolder, proposedRow: -1, proposedDropOperation: .on) == [])
    }

    /// The dragged item is named through a symlink to the folder it is dropped on.
    @Test func refusesSameFolderMoveThroughASymlink() {
        let link = fx.url.appendingPathComponent("link")
        try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: fx.url.appendingPathComponent("dst"))
        let wc = makeWindow([fx.url.appendingPathComponent("src"), fx.url.appendingPathComponent("dst")])
        let (table, ds) = dropTarget(wc)
        let drag = FakeDrag([link.appendingPathComponent("Inner")])
        #expect(ds.tableView!(table, validateDrop: drag, proposedRow: -1, proposedDropOperation: .on) == [])
        // Into a folder of that folder it is a real move.
        fx.dir("dst/Other")
        wc.paneGroup.panes[1].reload()
        #expect(wc.paneGroup.panes[1].browser.visibleItems.map(\.name) == ["Inner", "Other"])
        #expect(ds.tableView!(table, validateDrop: drag, proposedRow: 1, proposedDropOperation: .on) == .move)
    }

    /// A drop names its folder by another path than the pane does (a symlink to it, or
    /// the pane shows the link): the results are selected all the same.
    @Test func dropThroughASymlinkedPathSelectsTheResults() {
        let dst = fx.url.appendingPathComponent("dst")
        let link = fx.url.appendingPathComponent("link")
        try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: dst)
        fx.file("src/b.txt", "B")
        let wc = makeWindow([dst, link])
        let (real, linked) = (wc.paneGroup.panes[0], wc.paneGroup.panes[1])

        real.browser(real.browser, drop: [fx.url.appendingPathComponent("src/a.txt")], onto: link, kind: .copy)
        #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("a.txt").path))
        #expect(real.selectedItems.map(\.name) == ["a.txt"])

        linked.browser(linked.browser, drop: [fx.url.appendingPathComponent("src/b.txt")], onto: dst, kind: .copy)
        #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("b.txt").path))
        #expect(linked.selectedItems.map(\.name) == ["b.txt"])
    }

    @Test func dragWritesFileURLs() {
        let wc = makeWindow([fx.url.appendingPathComponent("src"), fx.url])
        let list = wc.paneGroup.panes[0].browser as! FileListViewController
        let writer = list.tableView(list.tableView, pasteboardWriterForRow: 0)
        #expect((writer as? NSURL)?.lastPathComponent == "a.txt")
    }
}
