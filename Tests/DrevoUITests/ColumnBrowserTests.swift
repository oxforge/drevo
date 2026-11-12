import AppKit
import Testing
@testable import DrevoCore
@testable import DrevoUI

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

    @Test func leftFromADeeperColumnFocusesItsParent() {
        let start = fx.url.appendingPathComponent("alpha")
        let wc = makeWindow([start, start], modes: [.columns, .columns])
        let pane = wc.paneGroup.activePane
        let cb = columns(wc)
        // A temp path's chain starts at "/", so the focused column is several levels deep
        // and ← only moves focus one column to the left.
        let depthBefore = cb.columns.count
        let focusBefore = cb.focusedIndex
        #expect(focusBefore > 0)
        #expect(pane.perform(.levelUp))
        #expect(cb.focusedIndex == focusBefore - 1)
        #expect(pane.currentDirectory.standardizedFileURL.path == fx.url.standardizedFileURL.path)
        #expect(pane.selectedItems.map(\.name) == ["alpha"])
        #expect(cb.columns.count <= depthBefore)
        #expect(pane.history.current.standardizedFileURL.path == fx.url.standardizedFileURL.path)
    }

    /// ← in the first column shows the folder above it. The pane has to hear about it:
    /// path bar, history (Back) and everything else that follows the current folder.
    @Test func leftAtFirstColumnGrowsUpwardAndThePaneFollows() throws {
        // The first column is the volume root. "/" has nothing above it, but the same
        // fixture reached through the Data volume starts at /System/Volumes/Data, which
        // has a parent. Read-only: nothing is written outside the fixture.
        let dataVolume = URL(fileURLWithPath: "/System/Volumes/Data")
        // The real path (/private/var/…): Foundation's resolved paths drop "/private",
        // and /var is a symlink that only exists at the root.
        let real = try #require(realpath(fx.url.path, nil), "the fixture has a real path")
        defer { free(real) }
        let viaData = URL(fileURLWithPath: dataVolume.path + String(cString: real))
        try #require(FileManager.default.fileExists(atPath: viaData.path), "the fixture is reachable through the Data volume")
        let wc = makeWindow([viaData, fx.url], modes: [.columns, .columns])
        let w = wc.window!
        let pane = wc.paneGroup.activePane
        let cb = columns(wc)
        try #require(cb.columns.first?.directory.path == dataVolume.path)
        func path(_ url: URL?) -> String? { url?.standardizedFileURL.path }

        let left = key(KeyCode.left, String(UnicodeScalar(NSLeftArrowFunctionKey)!), .function, window: w)
        for _ in 0..<40 where cb.focusedIndex > 0 { press(left, in: w) }
        try #require(cb.focusedIndex == 0)
        #expect(path(pane.currentDirectory) == dataVolume.path)
        #expect(path(pane.header.pathBar.url) == dataVolume.path)
        #expect(path(pane.history.current) == dataVolume.path)

        press(left, in: w)
        let parent = dataVolume.deletingLastPathComponent()
        #expect(cb.focusedIndex == 0)
        #expect(path(pane.currentDirectory) == parent.path, "the chain grew upward")
        #expect(pane.selectedItems.map(\.name) == ["Data"], "the folder you came from is selected")
        #expect(path(pane.header.pathBar.url) == parent.path, "the path bar follows")
        #expect(path(pane.history.current) == parent.path, "history follows")
        #expect(path(wc.window?.representedURL) == parent.path, "the window title follows")

        wc.perform(.back)
        #expect(path(pane.currentDirectory) == dataVolume.path, "Back returns to where ← started")
        #expect(path(pane.header.pathBar.url) == dataVolume.path)
        #expect(path(pane.history.current) == dataVolume.path)
    }

    @Test func selectingFileShowsPreview() throws {
        let wc = makeWindow([fx.url, fx.url], modes: [.columns, .columns])
        let pane = wc.paneGroup.activePane
        pane.browser.select([fx.url.appendingPathComponent("note.txt")])
        let cb = columns(wc)
        #expect(cb.columns.last?.directory.standardizedFileURL.path == fx.url.standardizedFileURL.path)
        let preview = try #require(cb.preview, "a selected file gets a preview after the last column")
        #expect(preview.items.map(\.name) == ["note.txt"])
        #expect(preview.titleLabel.stringValue == "note.txt")
        #expect(preview.superview != nil, "the preview is on screen")
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
