import AppKit
import Testing
@testable import DrevoCore
@testable import DrevoUI

@MainActor
@Suite(.serialized) struct SortingTests {
    let fx = Fixture()

    init() {
        let files: [(String, TimeInterval, Int)] = [("b.zip", 3000, 30), ("a.pdf", 1000, 300), ("c.zip", 2000, 3), ("d.md", 4000, 3000)]
        for (name, time, size) in files {
            let u = fx.file(name, String(repeating: "x", count: size))
            try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: u.path)
        }
        fx.dir("Folder")
    }

    func names(_ pane: PaneViewController) -> [String] { pane.browser.visibleItems.map(\.name) }

    @Test func columnsViewSortsByKeyAndReverses() {
        let wc = makeWindow([fx.url, fx.url], modes: [.columns, .columns])
        let pane = wc.paneGroup.activePane
        #expect(names(pane) == ["Folder", "a.pdf", "b.zip", "c.zip", "d.md"])
        wc.perform(.sortByModified)
        #expect(names(pane) == ["Folder", "d.md", "b.zip", "c.zip", "a.pdf"], "newest first, folders still on top")
        wc.perform(.sortByModified)
        #expect(names(pane) == ["Folder", "a.pdf", "c.zip", "b.zip", "d.md"], "same key again reverses")
        wc.perform(.sortBySize)
        #expect(names(pane) == ["Folder", "d.md", "a.pdf", "b.zip", "c.zip"], "largest first")
        #expect(pane.sortButton.titleText == "Size ↓")
        #expect(wc.paneGroup.panes[1].sort == FileSort(), "each pane has its own sort")
    }

    @Test func kindGroupsFilesByType() {
        let wc = makeWindow([fx.url, fx.url], modes: [.columns, .columns])
        let pane = wc.paneGroup.activePane
        wc.perform(.sortByKind)
        let files = Array(names(pane).dropFirst())
        let kinds = pane.browser.visibleItems.dropFirst().map(\.kind)
        #expect(kinds == kinds.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(abs(files.firstIndex(of: "b.zip")! - files.firstIndex(of: "c.zip")!) == 1, "zips sit together")
    }

    @Test func keyboardShortcutSorts() {
        let wc = makeWindow([fx.url, fx.url], modes: [.columns, .columns])
        NSApp.mainMenu = MainMenu.build(keyMap: wc.env.keyMap)
        let w = wc.window!
        // ⌃⌥⌘5
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option, .command], timestamp: 0,
                                 windowNumber: w.windowNumber, context: nil, characters: "5", charactersIgnoringModifiers: "5",
                                 isARepeat: false, keyCode: 23)!
        #expect(wc.env.keyMap.command(for: e) == .sortByModified)
        // The menu owns the key (no window is key in tests, so dispatch is checked separately).
        let item = MainMenu.item(for: .sortByModified, keyMap: wc.env.keyMap)
        #expect(item.keyEquivalent == "5" && item.keyEquivalentModifierMask == [.control, .option, .command])
        wc.perform(.sortByModified)
        #expect(wc.paneGroup.activePane.sort.key == .modified)
    }

    @Test func listHeadersFollowAndCreatedHasNoColumn() throws {
        let wc = makeWindow([fx.url, fx.url], modes: [.list, .list])
        let pane = wc.paneGroup.activePane
        let list = try #require(pane.browser as? FileListViewController)
        wc.perform(.sortByModified)
        #expect(list.tableView.sortDescriptors.first?.key == "modified")
        #expect(list.tableView.sortDescriptors.first?.ascending == false)
        wc.perform(.sortByCreated)
        #expect(pane.sort.key == .created, "no header column must not reset the sort to Name")
        #expect(list.tableView.sortDescriptors.isEmpty)
        // A header click still drives the pane's sort.
        list.tableView.sortDescriptors = [NSSortDescriptor(key: "size", ascending: true)]
        #expect(pane.sort.key == .size && pane.sort.ascending)
        #expect(pane.sortButton.titleText == "Size ↑")
    }

    @Test func viewSwitchKeepsSort() {
        let wc = makeWindow([fx.url, fx.url], modes: [.columns, .columns])
        let pane = wc.paneGroup.activePane
        wc.perform(.sortBySize)
        wc.perform(.listView)
        #expect(names(pane) == ["Folder", "d.md", "a.pdf", "b.zip", "c.zip"])
    }

    @Test func backgroundMenuOffersSortBy() throws {
        let wc = makeWindow([fx.url, fx.url], modes: [.columns, .columns])
        let pane = wc.paneGroup.activePane
        let menu = try #require(pane.browser(pane.browser, menuFor: []))
        let sortMenu = try #require(menu.items.first { $0.title == "Sort By" }?.submenu)
        #expect(sortMenu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["Name", "Kind", "Date Modified", "Date Created", "Size", "A to Z", "Z to A"])
        let kind = try #require(sortMenu.items.first { $0.title == "Kind" })
        _ = kind.target?.perform(kind.action, with: kind)
        #expect(pane.sort.key == .kind)
    }

    @Test func sortIsSavedAndRestored() throws {
        let wc = makeWindow([fx.url, fx.url], modes: [.columns, .list])
        wc.paneGroup.panes[1].chooseSort(.size)
        let saved = try #require(WindowState.decode(wc.env.preferences.savedWindowState))
        #expect(saved.sorts[1] == FileSort(key: .size, ascending: false))
        let restored = MainWindowController(env: wc.env, directories: saved.directories, viewModes: saved.viewModes, sorts: saved.sorts, autosave: false)
        #expect(restored.paneGroup.panes[1].sort.key == .size)
        // State from older builds (no sort fields) still loads.
        let legacy = Data(#"{"panes":[{"path":"/","viewMode":"list"}],"activeIndex":0}"#.utf8)
        #expect(WindowState.decode(legacy)?.sorts == [FileSort()])
    }
}
