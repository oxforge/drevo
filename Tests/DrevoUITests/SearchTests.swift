import AppKit
import Testing
@testable import DrevoCore
@testable import DrevoUI

/// ⌥⌘F: search the folder's tree and work with the results.
@MainActor
@Suite(.serialized) struct SearchTests {
    let fx = Fixture()
    let trash: URL

    init() {
        fx.file("notes.txt", "top")
        fx.file("docs/old notes.txt", "older")
        fx.file("docs/deep/Notes.md", "deep")
        fx.file("docs/other.png")
        fx.dir("docs/notes folder")
        trash = fx.dir(".T")
    }

    func window() -> MainWindowController {
        makeWindow([fx.url, fx.url], env: testEnvironment(trash: trash))
    }

    /// What the pane lists, without the scratch shell config `testEnvironment` puts next to the trash.
    func names(_ pane: PaneViewController) -> [String] {
        pane.browser.visibleItems.map(\.name).filter { !$0.hasPrefix("zdot-") }
    }

    @Test func searchShowsMatchesFromAllSubfoldersWithTheirLocation() throws {
        let wc = window()
        let pane = wc.paneGroup.activePane
        #expect(wc.canPerform(.search))
        wc.perform(.search)
        #expect(pane.header.isSearchMode)
        #expect(wc.window!.firstResponder === pane.header.filterField.currentEditor())
        pane.header.filterField.stringValue = "notes"
        pane.header.onSearchCommit?("notes")

        let results = try #require(pane.searchResults)
        // Folders first, then by name: the pane's sort order.
        #expect(names(pane) == ["notes folder", "Notes.md", "notes.txt", "old notes.txt"])
        #expect(pane.browser.visibleItems.map(results.location(of:)) == ["docs", "docs/deep", ".", "docs"])
        #expect(pane.searchQuery == "notes")
        #expect(FileIdentity.sameItem(pane.currentDirectory, fx.url))
        #expect(pane.statusBar.left.stringValue.hasPrefix("Search “notes”: 4 items"))
        #expect(pane.selectedItems.map(\.name) == ["notes folder"])
        #expect(results.hasFocus)
        // The other pane is untouched.
        #expect(wc.paneGroup.panes[1].searchQuery == nil)
    }

    @Test func nothingFoundSaysSo() throws {
        let wc = window()
        let pane = wc.paneGroup.activePane
        pane.search("zzz")
        #expect(names(pane).isEmpty)
        #expect(pane.statusBar.left.stringValue.contains("Search “zzz”"))
        // An empty query is no search.
        pane.search("  ")
        #expect(pane.searchQuery == nil)
        #expect(pane.searchResults == nil)
    }

    @Test func escapeGoesBackToTheFolder() {
        let wc = window()
        let pane = wc.paneGroup.activePane
        pane.search("notes")
        pane.browser.activeTableView!.keyDown(with: key(53, "\u{1b}", window: wc.window!))
        #expect(pane.searchQuery == nil)
        #expect(pane.browser is FileListViewController)
        #expect(names(pane) == ["docs", "notes.txt"])
        #expect(!pane.header.isSearchMode)
        #expect(!pane.header.isFiltering)
        #expect(pane.browser.hasFocus)
    }

    @Test func typingInTheResultsDoesNotFilterThem() {
        let wc = window()
        let pane = wc.paneGroup.activePane
        pane.search("notes")
        pane.browser.activeTableView!.keyDown(with: key(0, "o", window: wc.window!))
        #expect(pane.filter.isEmpty)
        #expect(names(pane).count == 4)
        // ⌘F goes to the search field with the query in it.
        wc.perform(.filter)
        #expect(pane.header.isSearchMode)
        #expect(pane.header.filterField.stringValue == "notes")
    }

    @Test func openingAFolderResultLeavesTheSearch() {
        let wc = window()
        let pane = wc.paneGroup.activePane
        pane.search("notes")
        pane.browser.select([fx.url.appendingPathComponent("docs/notes folder")])
        wc.perform(.open)
        #expect(pane.searchQuery == nil)
        #expect(pane.currentDirectory.lastPathComponent == "notes folder")
        // Back returns to the folder that was searched, not to the results.
        wc.perform(.back)
        #expect(FileIdentity.sameItem(pane.currentDirectory, fx.url))
        #expect(pane.searchResults == nil)
    }

    @Test func enclosingFolderRevealsTheResultInItsFolder() {
        let wc = window()
        let pane = wc.paneGroup.activePane
        pane.search("notes")
        pane.browser.select([fx.url.appendingPathComponent("docs/deep/Notes.md")])
        wc.perform(.enclosingFolder)
        #expect(pane.searchQuery == nil)
        #expect(pane.currentDirectory.lastPathComponent == "deep")
        #expect(pane.selectedItems.map(\.name) == ["Notes.md"])
    }

    @Test func fileCommandsWorkOnResults() throws {
        let opener = RecordingOpener()
        let wc = makeWindow([fx.url, fx.dir("target")], env: testEnvironment(trash: trash, opener: opener))
        let pane = wc.paneGroup.activePane
        pane.search("notes")
        let deep = fx.url.appendingPathComponent("docs/deep/Notes.md")

        // Open a file.
        pane.browser.select([deep])
        wc.perform(.open)
        #expect(opener.opened == [[deep]])

        // Copy to the other pane (F5) — confirmTransfers asks; the scripted prompt accepts.
        wc.perform(.copyToOtherPane)
        #expect(FileManager.default.fileExists(atPath: fx.url.appendingPathComponent("target/Notes.md").path))
        // The copy lies below the searched folder and matches, but nothing searched again.
        #expect(pane.searchQuery == "notes")

        // Move to Trash: the result leaves the list, the cursor stays in place.
        pane.browser.select([fx.url.appendingPathComponent("docs/old notes.txt")])
        wc.perform(.moveToTrash)
        #expect(!FileManager.default.fileExists(atPath: fx.url.appendingPathComponent("docs/old notes.txt").path))
        #expect(!names(pane).contains("old notes.txt"))
        #expect(pane.selectedItems.count == 1)

        // Undo brings the file back; it is found again by the next search.
        wc.env.operations.undoManager.undo()
        #expect(FileManager.default.fileExists(atPath: fx.url.appendingPathComponent("docs/old notes.txt").path))
        pane.search("notes")
        #expect(names(pane).contains("old notes.txt"))
    }

    @Test func aRenamedResultStaysInTheListWhileItStillMatches() throws {
        let wc = window()
        let pane = wc.paneGroup.activePane
        pane.search("notes")
        let old = fx.url.appendingPathComponent("docs/old notes.txt")
        let renamed: URL? = pane.operations.perform("Rename", in: nil) { try pane.operations.ops.rename(old, to: "new notes.txt") }
        pane.reload(selecting: [try #require(renamed)])
        #expect(names(pane).contains("new notes.txt"))
        #expect(!names(pane).contains("old notes.txt"))
        #expect(pane.selectedItems.map(\.name) == ["new notes.txt"])

        // Renamed to something the search doesn't match: gone from the results.
        let away: URL? = pane.operations.perform("Rename", in: nil) { try pane.operations.ops.rename(renamed!, to: "todo.txt") }
        pane.reload(selecting: [try #require(away)])
        #expect(!names(pane).contains("todo.txt"))
        #expect(names(pane).count == 3)
    }

    @Test func resultsFollowThePaneSortOrder() {
        let wc = window()
        let pane = wc.paneGroup.activePane
        pane.search("notes")
        pane.chooseSort(.name)   // name again: descending
        #expect(names(pane) == ["notes folder", "old notes.txt", "notes.txt", "Notes.md"])
        #expect(pane.searchQuery == "notes")
    }

    @Test func switchingViewOrTabLeavesTheSearch() {
        let wc = window()
        let pane = wc.paneGroup.activePane
        pane.search("notes")
        wc.perform(.columnsView)
        #expect(pane.searchQuery == nil)
        #expect(pane.browser is ColumnBrowserViewController)

        pane.search("notes")
        wc.perform(.newTab)
        #expect(pane.searchQuery == nil)
        pane.search("notes")
        wc.perform(.previousTab)
        #expect(pane.searchQuery == nil)
        #expect(pane.searchResults == nil)
        #expect(!pane.header.isSearchMode)
    }

    @Test func aSearchInTheBackgroundDeliversItsResults() async throws {
        let env = testEnvironment(trash: trash)
        env.runSearchesSynchronously = false
        let wc = makeWindow([fx.url, fx.url], env: env)
        let pane = wc.paneGroup.activePane
        pane.search("notes")
        let results = try #require(pane.searchResults)
        let deadline = Date().addingTimeInterval(10)
        while results.isSearching, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        #expect(!results.isSearching)
        #expect(names(pane).count == 4)
        #expect(!pane.statusBar.left.stringValue.contains("searching"))

        // Results of a search that was left don't show up in the folder.
        pane.search("notes")
        pane.endSearch()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        #expect(names(pane) == ["docs", "notes.txt"])
    }
}
