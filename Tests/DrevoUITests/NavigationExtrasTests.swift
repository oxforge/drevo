import AppKit
import Testing
@testable import DrevoCore
@testable import DrevoUI

@MainActor
@Suite(.serialized) struct NavigationExtrasTests {
    let fx = Fixture()

    init() {
        fx.dir("Documents/Projects")
        fx.dir("Downloads")
        fx.file("alpha.txt")
        fx.file("beta.txt")
        fx.file("gamma.md")
    }

    func window(_ modes: [ViewMode] = [.list, .list]) -> MainWindowController {
        makeWindow([fx.url, fx.url], modes: modes)
    }

    func waitFor(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    @Test func pathEditorNavigatesAndCompletes() throws {
        let wc = window()
        let pane = wc.paneGroup.activePane
        wc.perform(.goToPath)
        #expect(pane.header.isEditingPath)
        let editor = try #require(wc.window!.firstResponder as? NSTextView)
        editor.string = fx.url.path + "/Doc"
        _ = pane.header.control(pane.header.pathField, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:)))
        #expect(pane.header.pathField.stringValue == fx.url.path + "/Documents/")
        _ = pane.header.control(pane.header.pathField, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(!pane.header.isEditingPath)
        #expect(pane.currentDirectory.lastPathComponent == "Documents")
        #expect(pane.browser.hasFocus)
    }

    @Test func badPathKeepsEditing() throws {
        let wc = window()
        let pane = wc.paneGroup.activePane
        pane.beginPathEditing()
        let editor = try #require(wc.window!.firstResponder as? NSTextView)
        editor.string = "/definitely/not/here"
        _ = pane.header.control(pane.header.pathField, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(pane.header.isEditingPath)
        _ = pane.header.control(pane.header.pathField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(!pane.header.isEditingPath)
        #expect(pane.currentDirectory.standardizedFileURL.path == fx.url.standardizedFileURL.path)
    }

    @Test func slashAndTildeStartPathEditing() {
        let wc = window()
        let w = wc.window!
        press(key(44, "/", window: w), in: w)
        let pane = wc.paneGroup.activePane
        #expect(pane.header.isEditingPath)
        #expect(pane.header.pathField.stringValue == "/")
        pane.header.endPathEditing()
        press(key(50, "~", .shift, window: w), in: w)
        #expect(pane.header.pathField.stringValue == "~/")
    }

    @Test func relativePathsResolveAgainstCurrentFolder() throws {
        let wc = window()
        let pane = wc.paneGroup.activePane
        pane.beginPathEditing(prefill: "")
        let editor = try #require(wc.window!.firstResponder as? NSTextView)
        editor.string = "Documents/Projects"
        _ = pane.header.control(pane.header.pathField, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(pane.currentDirectory.lastPathComponent == "Projects")
    }

    @Test func filterNarrowsAndEscClears() throws {
        let wc = window()
        let pane = wc.paneGroup.activePane
        wc.perform(.filter)
        #expect(pane.header.isFiltering)
        pane.header.filterField.stringValue = "ta"
        pane.setFilter("ta")
        #expect(pane.browser.visibleItems.map(\.name) == ["beta.txt"])
        #expect(pane.statusBar.left.stringValue.hasPrefix("Filter “ta”"))
        let editor = try #require(wc.window!.firstResponder as? NSTextView)
        _ = pane.header.control(pane.header.filterField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(!pane.header.isFiltering)
        #expect(pane.browser.visibleItems.count == 5)
    }

    @Test func filterClearsOnNavigation() {
        let wc = window()
        let pane = wc.paneGroup.activePane
        pane.beginFilter()
        pane.setFilter("Doc")
        pane.navigate(to: fx.url.appendingPathComponent("Downloads"))
        #expect(pane.filter.isEmpty)
        #expect(!pane.header.isFiltering)
    }

    @Test func outsideChangesShowUpLive() {
        let wc = window([.list, .columns])
        let (list, cols) = (wc.paneGroup.panes[0], wc.paneGroup.panes[1])
        RunLoop.main.run(until: Date().addingTimeInterval(0.4)) // let the FSEvents stream start
        fx.file("from-outside.txt")
        #expect(waitFor { list.browser.visibleItems.contains { $0.name == "from-outside.txt" } })
        #expect(waitFor { cols.browser.visibleItems.contains { $0.name == "from-outside.txt" } })
        try? FileManager.default.removeItem(at: fx.url.appendingPathComponent("alpha.txt"))
        #expect(waitFor { !list.browser.visibleItems.contains { $0.name == "alpha.txt" } })
    }

    @Test func sidebarAddsAndRemovesFavorites() {
        let wc = window()
        let before = wc.sidebar.sections[0].items.count
        wc.paneGroup.activePane.browser.select([fx.url.appendingPathComponent("Downloads")])
        wc.perform(.addToSidebar)
        #expect(wc.sidebar.sections[0].items.count == before + 1)
        #expect(wc.sidebar.sections[0].items.last?.url.lastPathComponent == "Downloads")
        wc.sidebar.removeFavorite(fx.url.appendingPathComponent("Downloads"))
        #expect(wc.sidebar.sections[0].items.count == before)
    }

    @Test func sidebarClickNavigatesActivePane() {
        let wc = window()
        wc.sidebar.onNavigate?(fx.url.appendingPathComponent("Downloads"))
        #expect(wc.paneGroup.activePane.currentDirectory.lastPathComponent == "Downloads")
    }
}
