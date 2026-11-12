import AppKit
import Testing
@testable import FmanCore
@testable import FmanUI

/// Typing in a file list filters it (decision: focus stays in the list).
@MainActor
@Suite(.serialized) struct TypeToFilterTests {
    let fx = Fixture()

    init() {
        fx.dir("Docs")
        fx.file("Docs/inner.txt")
        fx.file("Docs/other.md")
        fx.dir("Downloads")
        fx.file("alpha.txt")
        fx.file("beta.txt")
        fx.file("shot.png")
        fx.file("Pic.PNG")
        fx.file("notes.png.bak")
    }

    /// US-layout key codes for the characters these tests type.
    static let keyCodes: [Character: (UInt16, NSEvent.ModifierFlags)] = [
        "a": (0, []), "s": (1, []), "d": (2, []), "h": (4, []), "z": (6, []), "c": (8, []), "b": (11, []),
        "e": (14, []), "t": (17, []), "o": (31, []), "i": (34, []), "p": (35, []), "l": (37, []),
        "n": (45, []), "g": (5, []), ".": (47, []), "*": (28, [.shift]), "?": (44, [.shift]),
    ]

    func type(_ text: String, in w: NSWindow) {
        for ch in text {
            let (code, flags) = Self.keyCodes[ch]!
            press(key(code, String(ch), flags, window: w), in: w)
        }
    }

    func backspace(_ w: NSWindow) { press(key(51, "\u{7f}", window: w), in: w) }
    func esc(_ w: NSWindow) { press(key(53, "\u{1b}", window: w), in: w) }

    func names(_ pane: PaneViewController) -> Set<String> { Set(pane.browser.visibleItems.map(\.name)) }

    @Test func typingFiltersAndKeepsFocusOnTheList() throws {
        let wc = makeWindow([fx.url, fx.url])
        let w = wc.window!
        let pane = wc.paneGroup.activePane
        type("ta", in: w)
        #expect(names(pane) == ["beta.txt"])
        #expect(pane.filter == "ta")
        #expect(w.firstResponder === pane.browser.activeTableView, "focus stays in the list")
        #expect(pane.header.isFiltering)
        #expect(pane.header.filterField.stringValue == "ta")
        #expect(pane.selectedItems.map(\.name) == ["beta.txt"])
    }

    @Test func filterIsCaseInsensitive() {
        let wc = makeWindow([fx.url, fx.url])
        type("pic", in: wc.window!)
        #expect(names(wc.paneGroup.activePane) == ["Pic.PNG"])
    }

    @Test func backspaceRemovesTheLastCharacterAndTheFilterWhenEmpty() {
        let wc = makeWindow([fx.url, fx.url])
        let w = wc.window!
        let pane = wc.paneGroup.activePane
        type("alp", in: w)
        #expect(names(pane) == ["alpha.txt"])
        backspace(w)
        #expect(pane.filter == "al")
        #expect(pane.header.filterField.stringValue == "al")
        backspace(w)
        backspace(w)
        #expect(pane.filter.isEmpty)
        #expect(!pane.header.isFiltering)
        #expect(pane.browser.visibleItems.count == 7)
    }

    @Test func escClearsTheTypedFilter() {
        let wc = makeWindow([fx.url, fx.url])
        let w = wc.window!
        let pane = wc.paneGroup.activePane
        type("beta", in: w)
        esc(w)
        #expect(pane.filter.isEmpty)
        #expect(!pane.header.isFiltering)
        #expect(pane.browser.visibleItems.count == 7)
    }

    @Test func wildcardsMatchTheWholeName() {
        let wc = makeWindow([fx.url, fx.url])
        let w = wc.window!
        let pane = wc.paneGroup.activePane
        type("*.png", in: w)
        #expect(names(pane) == ["shot.png", "Pic.PNG"])
        esc(w)
        type("?eta*", in: w)
        #expect(names(pane) == ["beta.txt"])
    }

    @Test func selectAllSelectsOnlyTheMatches() {
        let wc = makeWindow([fx.url, fx.url])
        let w = wc.window!
        let pane = wc.paneGroup.activePane
        type("*.png", in: w)
        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: w.firstResponder, from: nil)
        #expect(Set(pane.selectedItems.map(\.name)) == ["shot.png", "Pic.PNG"])
    }

    @Test func enteringAFolderWithReturnClearsTheFilter() {
        let wc = makeWindow([fx.url, fx.url])
        let w = wc.window!
        let pane = wc.paneGroup.activePane
        type("docs", in: w)
        #expect(pane.selectedItems.map(\.name) == ["Docs"])
        press(key(KeyCode.returnKey, "\r", window: w), in: w)
        #expect(pane.currentDirectory.lastPathComponent == "Docs")
        #expect(pane.filter.isEmpty)
        #expect(!pane.header.isFiltering)
        #expect(names(pane) == ["inner.txt", "other.md"])
        #expect(pane.selectedItems.map(\.name) == ["inner.txt"], "the cursor starts on the first row")
    }

    @Test func goingUpClearsTheFilter() {
        let wc = makeWindow([fx.url.appendingPathComponent("Docs"), fx.url])
        let w = wc.window!
        let pane = wc.paneGroup.activePane
        type("inn", in: w)
        press(key(KeyCode.left, String(UnicodeScalar(NSLeftArrowFunctionKey)!), .function, window: w), in: w)
        #expect(pane.currentDirectory.standardizedFileURL.path == fx.url.standardizedFileURL.path)
        #expect(pane.filter.isEmpty)
        #expect(pane.browser.visibleItems.count == 7)
    }

    @Test func columnsFilterOnlyTheCurrentColumnAndClearWhenLeavingIt() throws {
        let wc = makeWindow([fx.url, fx.url], modes: [.columns, .columns])
        let w = wc.window!
        let pane = wc.paneGroup.activePane
        let cb = try #require(pane.browser as? ColumnBrowserViewController)
        let right = key(KeyCode.right, String(UnicodeScalar(NSRightArrowFunctionKey)!), .function, window: w)
        press(right, in: w) // into Docs
        #expect(pane.currentDirectory.lastPathComponent == "Docs")
        type("inn", in: w)
        #expect(names(pane) == ["inner.txt"])
        func column(_ dir: URL) -> FolderColumn? {
            cb.columns.first { FileIdentity.sameItem($0.directory, dir) }
        }
        #expect(column(fx.url)?.items.count == 7, "the parent column is not filtered")
        press(key(KeyCode.left, String(UnicodeScalar(NSLeftArrowFunctionKey)!), .function, window: w), in: w)
        #expect(pane.filter.isEmpty)
        #expect(!pane.header.isFiltering)
        #expect(column(fx.url.appendingPathComponent("Docs"))?.items.count == 2, "the column that was filtered shows everything again")
    }

    @Test func typedFilterSurvivesAReload() {
        let wc = makeWindow([fx.url, fx.url])
        let w = wc.window!
        let pane = wc.paneGroup.activePane
        type("*.png", in: w)
        fx.file("new.png")
        pane.reload()
        #expect(names(pane) == ["shot.png", "Pic.PNG", "new.png"])
    }
}
