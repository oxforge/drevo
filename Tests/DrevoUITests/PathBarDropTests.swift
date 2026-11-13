import AppKit
import Testing
@testable import DrevoCore
@testable import DrevoUI

/// Files dragged onto a folder of the breadcrumb path go into that folder.
@MainActor
@Suite(.serialized) struct PathBarDropTests {
    let fx = Fixture()
    let deep: URL
    let file: URL

    init() {
        deep = fx.dir("top/mid/deep")
        file = fx.file("top/mid/deep/a.txt", "A")
    }

    /// A drag of `urls` hovering over the path bar segment for `folder` in `pane`.
    func drag(_ urls: [URL], over folder: URL, in pane: PaneViewController, mask: NSDragOperation = [.copy, .move, .link, .generic]) -> FakeDrag {
        let bar = pane.header.pathBar
        pane.view.window!.layoutIfNeeded()
        let drag = FakeDrag(urls, mask: mask)
        let button = bar.segmentButtons.first { FileIdentity.sameItem($0.url, folder) }!
        drag.draggingLocation = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        return drag
    }

    @Test func dropOnAnAncestorMovesTheFilesThere() {
        let wc = makeWindow([deep, fx.url])
        let pane = wc.paneGroup.panes[0]
        let bar = pane.header.pathBar
        let top = fx.url.appendingPathComponent("top")
        let d = drag([file], over: top, in: pane)

        #expect(bar.draggingEntered(d) == .move)
        #expect(bar.dropSegment?.isDropTarget == true)
        #expect(bar.performDragOperation(d))
        #expect(bar.dropSegment == nil)
        #expect(FileManager.default.fileExists(atPath: top.appendingPathComponent("a.txt").path))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // The pane re-read its folder.
        #expect(pane.browser.visibleItems.isEmpty)
    }

    @Test func optionDragCopies() {
        let wc = makeWindow([deep, fx.url])
        let pane = wc.paneGroup.panes[0]
        let mid = fx.url.appendingPathComponent("top/mid")
        let d = drag([file], over: mid, in: pane, mask: .copy)
        #expect(pane.header.pathBar.draggingUpdated(d) == .copy)
        #expect(pane.header.pathBar.performDragOperation(d))
        #expect(FileManager.default.fileExists(atPath: mid.appendingPathComponent("a.txt").path))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func refusesTheFolderTheFilesAreInAndAFolderIntoItself() {
        let wc = makeWindow([deep, fx.url])
        let pane = wc.paneGroup.panes[0]
        let bar = pane.header.pathBar
        // a.txt is already in "deep": moving it there is nothing.
        let same = drag([file], over: deep, in: pane)
        #expect(bar.draggingEntered(same) == [])
        #expect(bar.dropSegment == nil)
        #expect(!bar.performDragOperation(same))
        // "mid" can't go into "deep", which is inside it.
        let intoItself = drag([fx.url.appendingPathComponent("top/mid")], over: deep, in: pane)
        #expect(bar.draggingEntered(intoItself) == [])
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func leavingTheBarRemovesTheHighlight() {
        let wc = makeWindow([deep, fx.url])
        let pane = wc.paneGroup.panes[0]
        let bar = pane.header.pathBar
        let d = drag([file], over: fx.url.appendingPathComponent("top"), in: pane)
        _ = bar.draggingEntered(d)
        let segment = bar.dropSegment
        #expect(segment != nil)
        bar.draggingExited(d)
        #expect(bar.dropSegment == nil)
        #expect(segment?.isDropTarget == false)
        // Away from the segments there is nothing to drop on.
        d.draggingLocation = bar.convert(NSPoint(x: -50, y: bar.bounds.midY), to: nil)
        #expect(bar.draggingUpdated(d) == [])
    }
}
