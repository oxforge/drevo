import AppKit
import Testing
@testable import FmanCore
@testable import FmanUI

@MainActor
@Suite(.serialized) struct PagingTests {
    let fx = Fixture()

    init() {
        for i in 0..<150 { fx.file(String(format: "f%03d.txt", i)) }
    }

    /// fn+↓ etc. as the keyboard delivers them: function-key characters with .function set.
    func pagingKey(_ keyCode: UInt16, _ functionKey: Int, shift: Bool = false, window: NSWindow) -> NSEvent {
        key(keyCode, String(UnicodeScalar(functionKey)!), shift ? [.function, .shift] : .function, window: window)
    }

    func rows(_ pane: PaneViewController) -> [Int] {
        let names = pane.selectedItems.map(\.name)
        return names.compactMap { Int($0.dropFirst().prefix(3)) }
    }

    @Test func pageDownMovesTheSelectionByAPage() throws {
        let wc = makeWindow([fx.url, fx.url])
        let w = wc.window!
        let pane = wc.paneGroup.activePane
        let table = try #require(pane.browser.activeTableView)
        let page = table.rowsPerPage
        #expect(page > 5)
        #expect(rows(pane) == [0])
        press(pagingKey(121, NSPageDownFunctionKey, window: w), in: w)
        #expect(rows(pane) == [page])
        #expect(table.visibleRect.intersects(table.rect(ofRow: page)), "the new cursor is scrolled into view")
        press(pagingKey(116, NSPageUpFunctionKey, window: w), in: w)
        #expect(rows(pane) == [0])
        press(pagingKey(116, NSPageUpFunctionKey, window: w), in: w)
        #expect(rows(pane) == [0], "clamped at the top")
    }

    @Test func shiftPageDownSelectsAPageOfFiles() throws {
        let wc = makeWindow([fx.url, fx.url])
        let w = wc.window!
        let pane = wc.paneGroup.activePane
        let page = try #require(pane.browser.activeTableView).rowsPerPage
        pane.browser.select([fx.url.appendingPathComponent("f010.txt")])
        press(pagingKey(121, NSPageDownFunctionKey, shift: true, window: w), in: w)
        #expect(rows(pane) == Array(10...(10 + page)))
        press(pagingKey(121, NSPageDownFunctionKey, shift: true, window: w), in: w)
        #expect(rows(pane) == Array(10...(10 + 2 * page)))
        // Shrinking back keeps the anchor where the selection started.
        press(pagingKey(116, NSPageUpFunctionKey, shift: true, window: w), in: w)
        #expect(rows(pane) == Array(10...(10 + page)))
        // Upward from the anchor flips direction.
        press(pagingKey(116, NSPageUpFunctionKey, shift: true, window: w), in: w)
        press(pagingKey(116, NSPageUpFunctionKey, shift: true, window: w), in: w)
        #expect(rows(pane) == Array(0...10))
    }

    @Test func homeAndEndJumpAndShiftEndSelectsToTheBottom() {
        let wc = makeWindow([fx.url, fx.url])
        let w = wc.window!
        let pane = wc.paneGroup.activePane
        press(pagingKey(119, NSEndFunctionKey, window: w), in: w)
        #expect(rows(pane) == [149])
        press(pagingKey(115, NSHomeFunctionKey, window: w), in: w)
        #expect(rows(pane) == [0])
        pane.browser.select([fx.url.appendingPathComponent("f140.txt")])
        press(pagingKey(119, NSEndFunctionKey, shift: true, window: w), in: w)
        #expect(rows(pane) == Array(140...149))
    }

    @Test func pagingWorksInColumnsView() throws {
        let wc = makeWindow([fx.url, fx.url], modes: [.columns, .columns])
        let w = wc.window!
        let pane = wc.paneGroup.activePane
        let page = try #require(pane.browser.activeTableView).rowsPerPage
        press(pagingKey(121, NSPageDownFunctionKey, window: w), in: w)
        #expect(rows(pane) == [page])
        press(pagingKey(121, NSPageDownFunctionKey, shift: true, window: w), in: w)
        #expect(rows(pane) == Array(page...(2 * page)))
        #expect(pane.currentDirectory.standardizedFileURL.path == fx.url.standardizedFileURL.path)
    }
}
