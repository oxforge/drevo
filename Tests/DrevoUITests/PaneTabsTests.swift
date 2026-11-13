import AppKit
import Testing
@testable import DrevoCore
@testable import DrevoUI

/// Tabs inside a pane: ⌘T, ⌘W, ⌃⇥, and their place in the saved window state.
@MainActor
@Suite(.serialized) struct PaneTabsTests {
    let fx = Fixture()
    let a: URL
    let b: URL

    init() {
        a = fx.dir("a")
        b = fx.dir("b")
        fx.file("a/one.txt")
        fx.file("b/two.txt")
        fx.dir("b/inner")
    }

    @Test func aPaneStartsWithOneTabAndNoTabBar() {
        let wc = makeWindow([a, b])
        let pane = wc.paneGroup.activePane
        #expect(pane.tabCount == 1)
        #expect(pane.tabBar.isHidden)
        #expect(!wc.canPerform(.nextTab))
        #expect(wc.canPerform(.newTab))
    }

    @Test func newTabOpensTheSameFolderWithItsOwnHistory() {
        let wc = makeWindow([fx.url, b])
        let pane = wc.paneGroup.activePane
        pane.navigate(to: a)
        #expect(pane.canGoBack)
        #expect(wc.perform(.newTab))
        #expect(pane.tabCount == 2)
        #expect(pane.activeTabIndex == 1)
        #expect(FileIdentity.sameItem(pane.currentDirectory, a))
        #expect(!pane.canGoBack)
        #expect(!pane.tabBar.isHidden)
        #expect(pane.tabBar.titles == ["a", "a"])
        // The other pane has nothing to do with it.
        #expect(wc.paneGroup.panes[1].tabCount == 1)
    }

    @Test func eachTabKeepsItsFolderViewSortAndHistory() {
        let wc = makeWindow([a, fx.url])
        let pane = wc.paneGroup.activePane
        wc.perform(.newTab)
        pane.navigate(to: b)
        pane.setViewMode(.columns)
        pane.chooseSort(.size)
        pane.navigate(to: b.appendingPathComponent("inner"))

        wc.perform(.previousTab)
        #expect(pane.activeTabIndex == 0)
        #expect(FileIdentity.sameItem(pane.currentDirectory, a))
        #expect(pane.viewMode == .list)
        #expect(pane.sort.key == .name)
        #expect(pane.browser is FileListViewController)
        #expect(pane.browser.visibleItems.map(\.name) == ["one.txt"])
        #expect(!pane.canGoBack)
        #expect(pane.header.pathBar.url == pane.currentDirectory)

        wc.perform(.nextTab)
        #expect(pane.activeTabIndex == 1)
        #expect(pane.currentDirectory.lastPathComponent == "inner")
        #expect(pane.viewMode == .columns)
        #expect(pane.sort.key == .size)
        #expect(pane.canGoBack)
        wc.perform(.back)
        #expect(FileIdentity.sameItem(pane.currentDirectory, b))
        #expect(pane.tabBar.titles == ["a", "b"])
        // Next from the last tab wraps around.
        wc.perform(.nextTab)
        #expect(pane.activeTabIndex == 0)
    }

    @Test func controlTabSwitchesTabs() {
        let wc = makeWindow([a, b])
        NSApp.mainMenu = MainMenu.build(keyMap: wc.env.keyMap)
        let pane = wc.paneGroup.activePane
        wc.perform(.newTab)
        #expect(wc.env.keyMap.command(for: key(KeyCode.tab, "\t", [.control], window: wc.window!)) == .nextTab)
        #expect(wc.env.keyMap.command(for: key(KeyCode.tab, "\u{19}", [.control, .shift], window: wc.window!)) == .previousTab)
        pane.browser.activeTableView!.keyDown(with: key(KeyCode.tab, "\t", [.control], window: wc.window!))
        #expect(pane.activeTabIndex == 0)
        // Plain Tab still switches panes.
        pane.browser.activeTableView!.keyDown(with: key(KeyCode.tab, "\t", window: wc.window!))
        #expect(wc.paneGroup.activeIndex == 1)
    }

    @Test func closingATabShowsItsNeighbour() {
        let wc = makeWindow([a, fx.url])
        let pane = wc.paneGroup.activePane
        wc.perform(.newTab)
        pane.navigate(to: b)
        wc.perform(.newTab)
        pane.navigate(to: fx.url)
        #expect(pane.tabBar.titles.count == 3)

        // A background tab closes without disturbing the one on screen.
        pane.tabBar.items[0].otherMouseDown(with: NSEvent())
        #expect(pane.tabCount == 2)
        #expect(pane.activeTabIndex == 1)
        #expect(FileIdentity.sameItem(pane.currentDirectory, fx.url))

        // The active one hands over to the tab next to it.
        wc.perform(.closeTab)
        #expect(pane.tabCount == 1)
        #expect(FileIdentity.sameItem(pane.currentDirectory, b))
        #expect(pane.tabBar.isHidden)
    }

    @Test func closingTheLastTabClosesTheWindow() {
        let wc = makeWindow([a, b])
        var closed = false
        let token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: wc.window, queue: nil) { _ in closed = true }
        defer { NotificationCenter.default.removeObserver(token) }
        wc.perform(.newTab)
        wc.perform(.closeTab)
        #expect(!closed)
        #expect(wc.paneGroup.activePane.tabCount == 1)
        wc.perform(.closeTab)
        #expect(closed)
    }

    @Test func clickingATabSelectsItAndActivatesThePane() {
        let wc = makeWindow([a, b])
        let left = wc.paneGroup.panes[0]
        wc.perform(.newTab)
        left.navigate(to: b)
        wc.paneGroup.activate(index: 1)
        left.tabBar.items[0].mouseDown(with: NSEvent())
        #expect(wc.paneGroup.activeIndex == 0)
        #expect(left.activeTabIndex == 0)
        #expect(FileIdentity.sameItem(left.currentDirectory, a))
    }

    @Test func aTabWhoseFolderIsGoneOpensTheFolderAbove() {
        let wc = makeWindow([b.appendingPathComponent("inner"), fx.url])
        let pane = wc.paneGroup.activePane
        wc.perform(.newTab)
        pane.navigate(to: a)
        try! FileManager.default.removeItem(at: b.appendingPathComponent("inner"))
        wc.perform(.previousTab)
        #expect(FileIdentity.sameItem(pane.currentDirectory, b))
    }

    @Test func tabsAreSavedWithTheWindowAndRestored() throws {
        let env = testEnvironment(trash: fx.url.appendingPathComponent(".T"))
        let wc = makeWindow([a, fx.url], env: env)
        let pane = wc.paneGroup.activePane
        wc.perform(.newTab)
        pane.navigate(to: b)
        pane.setViewMode(.columns)
        wc.perform(.previousTab)

        let saved = try #require(WindowState.decode(env.preferences.savedWindowState))
        #expect(saved.panes[0].tabs?.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["a", "b"])
        #expect(saved.panes[0].tabs?.map(\.viewMode) == ["list", "columns"])
        #expect(saved.panes[0].activeTab == 0)
        #expect(saved.panes[1].tabs == nil)

        let state = saved.validated()
        let again = MainWindowController(env: env, directories: state.directories, viewModes: state.viewModes, sorts: state.sorts, autosave: false)
        again.paneGroup.restoreTabs(from: state)
        let restored = again.paneGroup.panes[0]
        #expect(restored.tabCount == 2)
        #expect(restored.activeTabIndex == 0)
        #expect(FileIdentity.sameItem(restored.currentDirectory, a))
        again.perform(.nextTab)
        #expect(FileIdentity.sameItem(restored.currentDirectory, b))
        #expect(restored.viewMode == .columns)
    }

    @Test func savedStateFromBeforeTabsStillLoads() throws {
        let old = Data(#"{"panes":[{"path":"/tmp","viewMode":"list"}],"activeIndex":0}"#.utf8)
        let state = try #require(WindowState.decode(old))
        #expect(state.panes[0].tabs == nil)
        // A saved tab whose folder is gone falls back to Home, like a pane's.
        var withTabs = state
        withTabs.panes[0].tabs = [.init(path: "/tmp", viewMode: "list"), .init(path: "/nonexistent/xyz", viewMode: "list")]
        #expect(withTabs.validated().panes[0].tabs?[1].path == FileManager.default.homeDirectoryForCurrentUser.path)
    }
}
