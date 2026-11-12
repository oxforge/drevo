import AppKit
import Testing
@testable import FmanCore
@testable import FmanUI

/// When the selected items leave a pane (moved away, deleted outside, undone), the cursor
/// stays where it was instead of disappearing — in both views.
@MainActor
@Suite(.serialized) struct SelectionAfterRemovalTests {
    let fx = Fixture()
    let prompts = ScriptedPrompts()
    var left: URL { fx.url.appendingPathComponent("left") }
    var right: URL { fx.url.appendingPathComponent("right") }

    /// Rows of the left pane: Folder, a.txt, b.txt, c.txt, d.txt.
    init() {
        fx.dir("left/Folder")
        for name in ["a", "b", "c", "d"] { fx.file("left/\(name).txt", name) }
        fx.dir("right")
    }

    func window(_ mode: ViewMode) -> MainWindowController {
        let env = testEnvironment(trash: fx.url.appendingPathComponent("_trash"), prompts: prompts)
        env.preferences.confirmTransfers = false
        return makeWindow([left, right], modes: [mode, mode], env: env)
    }

    func item(_ name: String) -> URL { left.appendingPathComponent(name) }
    func names(_ pane: PaneViewController) -> [String] { pane.browser.visibleItems.map(\.name) }
    func selected(_ pane: PaneViewController) -> [String] { pane.selectedItems.map(\.name) }
    func cursor(_ pane: PaneViewController) -> Int { pane.browser.activeTableView?.cursorRow ?? -1 }

    @Test(arguments: ViewMode.allCases)
    func movingTheMiddleRowAwaySelectsTheRowThatTookItsPlace(mode: ViewMode) {
        let wc = window(mode)
        let w = wc.window!
        let pane = wc.paneGroup.activePane
        pane.browser.select([item("b.txt")])
        #expect(cursor(pane) == 2)
        wc.perform(.moveToOtherPane)
        #expect(names(pane) == ["Folder", "a.txt", "c.txt", "d.txt"])
        #expect(selected(pane) == ["c.txt"])
        #expect(cursor(pane) == 2)
        // The symptom: with no cursor, ↓ started again from the top of the list.
        press(key(KeyCode.down, String(UnicodeScalar(NSDownArrowFunctionKey)!), .function, window: w), in: w)
        #expect(selected(pane) == ["d.txt"])
    }

    @Test(arguments: ViewMode.allCases)
    func movingTheLastRowAwaySelectsTheNewLastRow(mode: ViewMode) {
        let wc = window(mode)
        let pane = wc.paneGroup.activePane
        pane.browser.select([item("d.txt")])
        wc.perform(.moveToOtherPane)
        #expect(selected(pane) == ["c.txt"])
        #expect(cursor(pane) == 3)
    }

    @Test(arguments: ViewMode.allCases)
    func movingSeveralRowsAwaySelectsTheRowAfterThem(mode: ViewMode) {
        let wc = window(mode)
        let pane = wc.paneGroup.activePane
        pane.browser.select([item("a.txt"), item("b.txt")])
        wc.perform(.moveToOtherPane)
        #expect(names(pane) == ["Folder", "c.txt", "d.txt"])
        #expect(selected(pane) == ["c.txt"])
    }

    @Test(arguments: ViewMode.allCases)
    func movingEverythingAwayLeavesAnEmptySelection(mode: ViewMode) {
        let wc = window(mode)
        let pane = wc.paneGroup.activePane
        pane.browser.select(pane.browser.visibleItems.map(\.url))
        wc.perform(.moveToOtherPane)
        #expect(names(pane).isEmpty)
        #expect(selected(pane).isEmpty)
        #expect(cursor(pane) == -1)
    }

    @Test(arguments: ViewMode.allCases)
    func deletingTheSelectedFileOutsideKeepsTheCursorInPlace(mode: ViewMode) throws {
        let wc = window(mode)
        let pane = wc.paneGroup.activePane
        pane.browser.select([item("b.txt")])
        try FileManager.default.removeItem(at: item("b.txt"))
        pane.reloadForExternalChange()
        #expect(selected(pane) == ["c.txt"])
        #expect(cursor(pane) == 2)
        // The last row goes: the new last row is selected.
        pane.browser.select([item("d.txt")])
        try FileManager.default.removeItem(at: item("d.txt"))
        pane.reloadForExternalChange()
        #expect(selected(pane) == ["c.txt"])
        #expect(cursor(pane) == 2)
    }

    @Test(arguments: ViewMode.allCases)
    func undoThatRemovesTheSelectedItemKeepsTheCursorInPlace(mode: ViewMode) {
        let wc = window(mode)
        let pane = wc.paneGroup.activePane
        pane.browser.select([item("b.txt")])
        wc.perform(.duplicate)
        #expect(selected(pane) == ["b copy.txt"])
        let row = cursor(pane)
        #expect(row > 0)
        wc.env.operations.undoManager.undo()
        #expect(!names(pane).contains("b copy.txt"))
        #expect(selected(pane).count == 1)
        #expect(cursor(pane) == row)
    }

    @Test(arguments: ViewMode.allCases)
    func aSurvivingSelectionIsKept(mode: ViewMode) throws {
        let wc = window(mode)
        let pane = wc.paneGroup.activePane
        pane.browser.select([item("b.txt"), item("d.txt")])
        try FileManager.default.removeItem(at: item("b.txt"))
        pane.reloadForExternalChange()
        #expect(selected(pane) == ["d.txt"])
    }

    @Test(arguments: ViewMode.allCases)
    func moveToTrashStillSelectsTheNextRow(mode: ViewMode) {
        let wc = window(mode)
        let pane = wc.paneGroup.activePane
        pane.browser.select([item("b.txt")])
        wc.perform(.moveToTrash)
        #expect(selected(pane) == ["c.txt"])
        pane.browser.select([item("d.txt")])
        wc.perform(.moveToTrash)
        #expect(selected(pane) == ["c.txt"])
        wc.env.operations.undoManager.undo()
        #expect(names(pane).contains("d.txt"))
    }

    /// A filter that hides the selection starts at the first match, not at the old row.
    @Test(arguments: ViewMode.allCases)
    func filteringTheSelectionAwaySelectsTheFirstMatch(mode: ViewMode) {
        fx.file("left/zz.md")
        let wc = window(mode)
        let pane = wc.paneGroup.activePane
        pane.browser.select([item("zz.md")])
        #expect(cursor(pane) == 5)
        pane.setFilter("txt")
        #expect(names(pane) == ["a.txt", "b.txt", "c.txt", "d.txt"])
        #expect(selected(pane) == ["a.txt"])
    }

    // MARK: Columns view: what follows the last column matches the new selection

    @Test func columnsShowAPreviewOfTheFileThatTookTheFoldersPlace() throws {
        let wc = window(.columns)
        let pane = wc.paneGroup.activePane
        let cb = try #require(pane.browser as? ColumnBrowserViewController)
        pane.browser.select([item("Folder")])
        #expect(cb.columns.last?.directory.lastPathComponent == "Folder")
        wc.perform(.moveToOtherPane)
        #expect(selected(pane) == ["a.txt"])
        #expect(cb.columns.last?.directory.lastPathComponent == "left", "the moved folder's column is gone")
        #expect(cb.preview?.items.map(\.name) == ["a.txt"])
        #expect(pane.currentDirectory.lastPathComponent == "left")
    }

    @Test func columnsShowTheFolderThatTookTheFoldersPlace() throws {
        fx.file("left/Aaa/inside.txt")
        let wc = window(.columns)
        let pane = wc.paneGroup.activePane
        let cb = try #require(pane.browser as? ColumnBrowserViewController)
        pane.browser.select([item("Aaa")])
        #expect(cb.columns.last?.directory.lastPathComponent == "Aaa")
        wc.perform(.moveToOtherPane)
        #expect(selected(pane) == ["Folder"])
        #expect(cb.columns.last?.directory.lastPathComponent == "Folder")
        #expect(cb.preview == nil)
        #expect(pane.currentDirectory.lastPathComponent == "left")
    }

    @Test func columnsDropTheColumnOfAFolderDeletedOutside() throws {
        fx.file("left/Folder/inside.txt")
        let wc = window(.columns)
        let pane = wc.paneGroup.activePane
        let cb = try #require(pane.browser as? ColumnBrowserViewController)
        pane.browser.select([item("Folder")])
        try FileManager.default.removeItem(at: item("Folder"))
        pane.reloadForExternalChange()
        #expect(selected(pane) == ["a.txt"])
        #expect(cb.columns.last?.directory.lastPathComponent == "left")
        #expect(cb.preview?.items.map(\.name) == ["a.txt"])
    }
}
