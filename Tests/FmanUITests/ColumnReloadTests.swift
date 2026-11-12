import AppKit
import Testing
@testable import FmanCore
@testable import FmanUI

/// Columns view after a change on disk: only the columns whose folder changed are read
/// again; operations, undo and preference changes still re-read everything.
@MainActor
@Suite(.serialized) struct ColumnReloadTests {
    let fx = Fixture()
    var alpha: URL { fx.url.appendingPathComponent("alpha") }
    var inner: URL { fx.url.appendingPathComponent("alpha/inner") }

    init() {
        fx.dir("alpha/inner/deep")
        fx.file("alpha/a.txt")
        fx.dir("beta")
        fx.file("note.txt")
    }

    /// The left pane shows …/alpha/inner (with "deep" after it), the right one the fixture.
    func window() -> MainWindowController {
        makeWindow([inner, fx.url], modes: [.columns, .columns])
    }

    func columns(_ pane: PaneViewController) -> ColumnBrowserViewController {
        pane.browser as! ColumnBrowserViewController
    }

    /// The set FSEvents would report for changes in `folders`.
    func changed(_ folders: URL...) -> Set<String> {
        Set(folders.map { DirectoryWatcher.normalize($0.path) })
    }

    func loads(_ cb: ColumnBrowserViewController) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: cb.columns.map { ($0.directory.standardizedFileURL.path, $0.loadCount) })
    }

    @Test func aChangeInOneFolderReadsOnlyThatColumnAgain() throws {
        let wc = window()
        let (pane, other) = (wc.paneGroup.panes[0], wc.paneGroup.panes[1])
        let cb = columns(pane)
        #expect(cb.columns.count > 3)
        let before = loads(cb)
        let otherBefore = loads(columns(other))
        let columnsBefore = cb.columns.map(ObjectIdentifier.init)
        let selectionsBefore = cb.columns.map(\.tableView.selectedRowIndexes)

        fx.file("alpha/inner/new.txt")
        wc.foldersChanged(changed(inner))

        var expected = before
        expected[inner.standardizedFileURL.path, default: 0] += 1
        #expect(loads(cb) == expected, "only the column of the changed folder is read again")
        #expect(loads(columns(other)) == otherBefore, "a pane that doesn't show the folder is left alone")
        #expect(pane.browser.visibleItems.map(\.name).contains("new.txt"))
        #expect(cb.columns.map(ObjectIdentifier.init) == columnsBefore, "no column was rebuilt")
        #expect(cb.columns.map(\.tableView.selectedRowIndexes) == selectionsBefore)
        #expect(pane.currentDirectory.lastPathComponent == "inner")
        #expect(cb.columns.last?.directory.lastPathComponent == "deep")
    }

    @Test func aChangeInAnEarlierColumnLeavesTheLaterOnesAlone() {
        let wc = window()
        let pane = wc.paneGroup.panes[0]
        let cb = columns(pane)
        let before = loads(cb)
        fx.file("added.txt")
        wc.foldersChanged(changed(fx.url))
        var expected = before
        expected[fx.url.standardizedFileURL.path, default: 0] += 1
        #expect(loads(cb) == expected)
        let fixtureColumn = cb.columns.first { $0.directory.standardizedFileURL.path == fx.url.standardizedFileURL.path }
        #expect(fixtureColumn?.items.map(\.name).contains("added.txt") == true)
        #expect(fixtureColumn?.selectedItems.map(\.name) == ["alpha"])
        #expect(pane.currentDirectory.lastPathComponent == "inner")
    }

    @Test func operationsAndPlainReloadsStillReadEveryColumn() {
        let wc = window()
        let pane = wc.paneGroup.panes[0]
        let cb = columns(pane)
        let before = loads(cb)
        pane.reloadForExternalChange()
        #expect(loads(cb) == before.mapValues { $0 + 1 })
        wc.env.operations.postChange() // an operation or undo finished
        #expect(loads(cb) == before.mapValues { $0 + 2 })
        wc.env.preferences.showHidden.toggle()
        #expect(loads(cb) == before.mapValues { $0 + 3 })
    }

    @Test func newListingOptionsReadEveryColumnWhateverChanged() {
        let wc = window()
        let cb = columns(wc.paneGroup.panes[0])
        let before = loads(cb)
        cb.reload(options: ListingOptions(showHidden: true), changedFolders: changed(inner))
        #expect(loads(cb) == before.mapValues { $0 + 1 })
    }

    @Test func aFolderThatVanishedTakesItsColumnsAway() throws {
        let wc = window()
        let pane = wc.paneGroup.panes[0]
        let cb = columns(pane)
        try FileManager.default.removeItem(at: inner)
        wc.foldersChanged(changed(alpha))
        #expect(cb.columns.last?.directory.lastPathComponent == "alpha")
        #expect(pane.currentDirectory.lastPathComponent == "alpha")
        #expect(pane.selectedItems.map(\.name) == ["a.txt"], "the row that took the folder's place")
        #expect(cb.preview?.items.map(\.name) == ["a.txt"])
    }

    func watchedFolders(_ wc: MainWindowController) -> Set<String> {
        Set(wc.paneGroup.panes.flatMap(\.shownDirectories).map { DirectoryWatcher.normalize($0.path) })
    }

    /// The pane was in a folder that got deleted: it is in the parent now, and says so
    /// everywhere, not only in the path bar.
    @Test func thePaneFollowsWhenItsFolderVanishes() throws {
        let wc = window()
        let pane = wc.paneGroup.panes[0]
        // Came here from elsewhere, so there is something to go back to.
        pane.navigate(to: fx.url.appendingPathComponent("beta"))
        pane.navigate(to: inner)
        #expect(wc.window?.title == "inner")
        #expect(wc.watchedFolders.contains(DirectoryWatcher.normalize(inner.path)))
        var changes = 0
        let onChange = pane.onChange
        pane.onChange = { p in changes += 1; onChange?(p) }

        try FileManager.default.removeItem(at: inner)
        wc.foldersChanged(changed(alpha))

        #expect(pane.currentDirectory.lastPathComponent == "alpha")
        #expect(pane.history.current.standardizedFileURL.path == alpha.standardizedFileURL.path, "the history is where the pane is")
        #expect(pane.history.backStack.map(\.lastPathComponent) == [inner.lastPathComponent, "beta"],
                "the deleted folder isn't added to the Back stack")
        #expect(!pane.canGoForward)
        #expect(changes > 0, "the pane reports the move")
        #expect(wc.window?.title == "alpha")
        #expect(wc.window?.representedURL?.lastPathComponent == "alpha")
        #expect(wc.watchedFolders == watchedFolders(wc))
        #expect(!wc.watchedFolders.contains(DirectoryWatcher.normalize(inner.path)))
    }

    /// A column after the focused one goes away with its folder: it isn't watched any more.
    @Test func columnsRemovedByAReloadAreNoLongerWatched() throws {
        let wc = makeWindow([alpha, fx.url], modes: [.columns, .list])
        let pane = wc.paneGroup.panes[0]
        let cb = columns(pane)
        #expect(pane.selectedItems.map(\.name) == ["inner"])
        #expect(cb.columns.last?.directory.lastPathComponent == "inner")
        #expect(wc.watchedFolders == watchedFolders(wc))
        #expect(wc.watchedFolders.contains(DirectoryWatcher.normalize(inner.path)))

        try FileManager.default.removeItem(at: inner)
        wc.foldersChanged(changed(alpha))

        #expect(cb.columns.last?.directory.lastPathComponent == "alpha")
        #expect(pane.currentDirectory.lastPathComponent == "alpha")
        #expect(pane.history.current.standardizedFileURL.path == alpha.standardizedFileURL.path)
        #expect(!pane.canGoBack)
        #expect(wc.watchedFolders == watchedFolders(wc))
        #expect(!wc.watchedFolders.contains(DirectoryWatcher.normalize(inner.path)))
    }

    /// The check for vanished folders doesn't depend on their parent being reported.
    @Test func aVanishedFolderIsNoticedEvenIfOnlyAnotherColumnWasReported() throws {
        let wc = window()
        let pane = wc.paneGroup.panes[0]
        let cb = columns(pane)
        try FileManager.default.removeItem(at: inner)
        wc.foldersChanged(changed(fx.url))
        #expect(cb.columns.last?.directory.lastPathComponent == "alpha")
        #expect(cb.columns.last?.items.map(\.name) == ["a.txt"])
        #expect(pane.currentDirectory.lastPathComponent == "alpha")
    }

    @Test func aChangeDuringARenameWaitsAndThenReadsEverything() throws {
        let wc = window()
        let w = wc.window!
        let pane = wc.paneGroup.panes[0]
        let cb = columns(pane)
        fx.file("alpha/inner/old.txt")
        pane.reload(selecting: [inner.appendingPathComponent("old.txt")])
        wc.perform(.rename)
        let editor = try #require(w.firstResponder as? NSTextView)
        let before = loads(cb)
        fx.file("alpha/inner/new.txt")
        wc.foldersChanged(changed(inner))
        #expect(w.firstResponder === editor, "still editing")
        #expect(loads(cb) == before, "nothing is read while a name is being typed")
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(pane.browser.visibleItems.map(\.name).contains("new.txt"))
        #expect(pane.selectedItems.map(\.name) == ["old.txt"])
    }
}
