import AppKit
import Testing
@testable import FmanCore
@testable import FmanUI

@MainActor
@Suite(.serialized) struct ReviewUIRegressionTests {
    let fx = Fixture()
    let prompts = ScriptedPrompts()

    init() {
        fx.file("note.txt", "N")
        fx.dir("alpha/inner/deep")
        fx.dir("Target")
        fx.dir("Target/sub")
    }

    func window(_ modes: [ViewMode] = [.list, .list]) -> MainWindowController {
        makeWindow([fx.url, fx.url.appendingPathComponent("Target")], modes: modes,
                   env: testEnvironment(trash: fx.url.appendingPathComponent(".T"), prompts: prompts))
    }

    func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: fx.url.appendingPathComponent(p).path) }

    @Test func fileChangesDoNotCommitAHalfTypedRename() throws {
        let wc = window()
        let w = wc.window!
        let pane = wc.paneGroup.activePane
        pane.browser.select([fx.url.appendingPathComponent("note.txt")])
        wc.perform(.rename)
        let editor = try #require(w.firstResponder as? NSTextView)
        editor.string = "half"
        wc.env.operations.postChange() // e.g. a background copy finishing
        #expect(w.firstResponder === editor, "still editing")
        #expect(exists("note.txt"))
        #expect(!exists("half"))
        editor.string = "finished.txt"
        w.makeFirstResponder(pane.browser.activeTableView)
        #expect(exists("finished.txt"))
        #expect(pane.selectedItems.map(\.name) == ["finished.txt"])
    }

    /// A rename anywhere postpones every pane's reload; when it ends, every pane that
    /// waited catches up, not only the one that was renaming.
    @Test func cancellingARenameReloadsTheOtherPanesThatWaited() throws {
        let wc = window()
        let w = wc.window!
        let (left, right) = (wc.paneGroup.panes[0], wc.paneGroup.panes[1])
        // A pane in another window waits too: there is one rename editor per app.
        let other = makeWindow([fx.url.appendingPathComponent("Target"), fx.url],
                               env: testEnvironment(trash: fx.url.appendingPathComponent(".T2"), prompts: prompts))
        let elsewhere = other.paneGroup.panes[0]
        left.browser.select([fx.url.appendingPathComponent("note.txt")])
        wc.perform(.rename)
        let editor = try #require(w.firstResponder as? NSTextView)
        editor.string = "half"

        fx.file("Target/arrived.txt")
        right.reloadForExternalChange()
        elsewhere.reloadForExternalChange()
        #expect(w.firstResponder === editor, "still editing")
        #expect(!right.browser.visibleItems.contains { $0.name == "arrived.txt" }, "the reload waits for the rename")

        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(exists("note.txt"))
        #expect(right.browser.visibleItems.contains { $0.name == "arrived.txt" })
        #expect(elsewhere.browser.visibleItems.contains { $0.name == "arrived.txt" })
        // Plain values: a failed expectation on a pane property would dump the whole pane.
        let stillWaiting = [right.reloadPendingAfterRename, elsewhere.reloadPendingAfterRename]
        #expect(stillWaiting == [false, false])
    }

    @Test func aRenameThatFailsReloadsTheOtherPanesThatWaited() throws {
        fx.file("taken.txt")
        let wc = window()
        let w = wc.window!
        let (left, right) = (wc.paneGroup.panes[0], wc.paneGroup.panes[1])
        left.browser.select([fx.url.appendingPathComponent("note.txt")])
        wc.perform(.rename)
        let editor = try #require(w.firstResponder as? NSTextView)
        fx.file("Target/arrived.txt")
        right.reloadForExternalChange()
        editor.string = "taken.txt"
        w.makeFirstResponder(left.browser.activeTableView)
        #expect(prompts.errors.count == 1)
        #expect(right.browser.visibleItems.contains { $0.name == "arrived.txt" })
        let stillWaiting = right.reloadPendingAfterRename
        #expect(!stillWaiting)
    }

    @Test func rightClickInAnEarlierColumnDoesNotCrash() throws {
        let wc = window([.columns, .columns])
        let pane = wc.paneGroup.activePane
        pane.navigate(to: fx.url.appendingPathComponent("alpha/inner"))
        let cb = pane.browser as! ColumnBrowserViewController
        let deepest = cb.focusedIndex
        #expect(deepest >= 2)
        // Right-click a row that isn't selected in an earlier column: the selection change
        // removes the focused column.
        let earlier = cb.columns[deepest - 2]
        let table = earlier.tableView
        table.layoutSubtreeIfNeeded()
        let row = try #require(earlier.items.firstIndex { $0.name == "Target" })
        #expect(!table.selectedRowIndexes.contains(row))
        let rowRect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: rowRect.midX, y: rowRect.midY), to: nil)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                       windowNumber: wc.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        _ = table.menu(for: event)
        #expect(cb.columns.indices.contains(cb.focusedIndex))
        #expect(pane.selectedItems.map(\.name) == ["Target"])
        #expect(pane.currentDirectory.standardizedFileURL.path == earlier.directory.standardizedFileURL.path)
    }

    @Test func relativeDestinationResolvesAgainstSourcePane() {
        let wc = window()
        wc.env.preferences.confirmTransfers = true
        prompts.typedDestination = "alpha"
        wc.paneGroup.activePane.browser.select([fx.url.appendingPathComponent("note.txt")])
        wc.perform(.copyToOtherPane)
        #expect(prompts.askedBase?.standardizedFileURL.path == fx.url.standardizedFileURL.path)
        #expect(exists("alpha/note.txt"))
    }
}
