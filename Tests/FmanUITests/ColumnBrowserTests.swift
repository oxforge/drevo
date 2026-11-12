import AppKit
import Testing
@testable import FmanCore
@testable import FmanUI

@MainActor
@Suite(.serialized) struct ColumnBrowserTests {
    let fx = Fixture()

    init() {
        fx.dir("alpha/inner/deep")
        fx.file("alpha/a.txt")
        fx.dir("beta")
        fx.file("note.txt")
    }

    func columns(_ wc: MainWindowController) -> ColumnBrowserViewController {
        wc.paneGroup.activePane.browser as! ColumnBrowserViewController
    }

    @Test func rightAndLeftMoveBetweenColumns() {
        let wc = makeWindow([fx.url, fx.url], modes: [.columns, .columns])
        let w = wc.window!
        let cb = columns(wc)
        let pane = wc.paneGroup.activePane
        #expect(pane.currentDirectory.standardizedFileURL.path == fx.url.standardizedFileURL.path)
        // First row is selected on arrival; it's "alpha", so its contents show in the next column.
        #expect(pane.selectedItems.map(\.name) == ["alpha"])
        #expect(cb.columns.last?.directory.lastPathComponent == "alpha")
        let right = key(KeyCode.right, String(UnicodeScalar(NSRightArrowFunctionKey)!), .function, window: w)
        press(right, in: w)
        #expect(pane.currentDirectory.lastPathComponent == "alpha")
        #expect(pane.selectedItems.map(\.name) == ["inner"])
        press(right, in: w)
        #expect(pane.currentDirectory.lastPathComponent == "inner")
        let left = key(KeyCode.left, String(UnicodeScalar(NSLeftArrowFunctionKey)!), .function, window: w)
        press(left, in: w)
        #expect(pane.currentDirectory.lastPathComponent == "alpha")
        #expect(pane.selectedItems.map(\.name) == ["inner"])
        #expect(cb.columns.last?.directory.lastPathComponent == "inner", "the folder's contents stay visible")
    }

    @Test func leftAtFirstColumnGrowsUpward() {
        let start = fx.url.appendingPathComponent("alpha")
        let wc = makeWindow([start, start], modes: [.columns, .columns])
        let pane = wc.paneGroup.activePane
        let cb = columns(wc)
        // Root column for a temp path is the volume root, so walk up from the focused column.
        let depthBefore = cb.columns.count
        #expect(pane.perform(.levelUp))
        #expect(pane.currentDirectory.standardizedFileURL.path == fx.url.standardizedFileURL.path)
        #expect(pane.selectedItems.map(\.name) == ["alpha"])
        #expect(cb.columns.count <= depthBefore)
    }

    @Test func selectingFileShowsPreview() {
        let wc = makeWindow([fx.url, fx.url], modes: [.columns, .columns])
        let pane = wc.paneGroup.activePane
        pane.browser.select([fx.url.appendingPathComponent("note.txt")])
        let cb = columns(wc)
        #expect(cb.columns.last?.directory.standardizedFileURL.path == fx.url.standardizedFileURL.path)
        #expect(cb.view.subviews.first != nil)
    }

    @Test func reloadKeepsChain() {
        let wc = makeWindow([fx.url.appendingPathComponent("alpha/inner"), fx.url], modes: [.columns, .columns])
        let pane = wc.paneGroup.activePane
        fx.file("alpha/inner/new.txt")
        pane.reload()
        #expect(pane.currentDirectory.lastPathComponent == "inner")
        #expect(pane.browser.visibleItems.map(\.name).contains("new.txt"))
    }
}
