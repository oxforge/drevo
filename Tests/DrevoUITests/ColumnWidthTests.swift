import AppKit
import Testing
@testable import DrevoCore
@testable import DrevoUI

/// Dragging a column's edge in Columns view.
@MainActor
@Suite(.serialized) struct ColumnWidthTests {
    let fx = Fixture()
    let inner: URL

    init() {
        inner = fx.dir("outer/inner")
        fx.file("outer/inner/a.txt")
    }

    func columns(_ wc: MainWindowController, pane: Int = 0) -> ColumnBrowserViewController {
        wc.paneGroup.panes[pane].browser as! ColumnBrowserViewController
    }

    func shownWidths(_ browser: ColumnBrowserViewController) -> [CGFloat] {
        browser.view.layoutSubtreeIfNeeded()
        return browser.columns.map { $0.container.frame.width }
    }

    @Test func draggingAnEdgeResizesThatColumnOnly() {
        let wc = makeWindow([inner, fx.url], modes: [.columns, .list])
        let browser = columns(wc)
        let last = browser.columns.count - 1
        browser.columns[last].resizeHandleForTesting.drag(from: 230, by: 70, option: false)
        var expected = [CGFloat](repeating: 230, count: browser.columns.count)
        expected[last] = 300
        #expect(shownWidths(browser) == expected)
        #expect(wc.env.preferences.columnWidth == 230)

        // The folder keeps its width when the pane goes elsewhere and comes back.
        let pane = wc.paneGroup.panes[0]
        pane.navigate(to: fx.url)
        pane.navigate(to: inner)
        #expect(shownWidths(columns(wc)).last == 300)
    }

    @Test func optionDragResizesEveryColumnAndIsRemembered() {
        let env = testEnvironment(trash: fx.url.appendingPathComponent("trash"))
        let wc = makeWindow([inner, fx.url], modes: [.columns, .list], env: env)
        let browser = columns(wc)
        browser.columns[0].resizeHandleForTesting.drag(from: 230, by: -50, option: true)
        #expect(Set(shownWidths(browser)) == [180])
        #expect(env.preferences.columnWidth == 180)

        // Columns opened later, here and in other windows, start at that width.
        let other = makeWindow([inner], modes: [.columns], env: env)
        #expect(Set(shownWidths(columns(other))) == [180])
    }

    @Test func widthStaysWithinLimits() {
        let wc = makeWindow([inner, fx.url], modes: [.columns, .list])
        let browser = columns(wc)
        browser.setWidth(10, ofColumn: 0, allColumns: false)
        #expect(shownWidths(browser)[0] == Preferences.columnWidthRange.lowerBound)
        browser.setWidth(5000, ofColumn: 0, allColumns: true)
        #expect(wc.env.preferences.columnWidth == Preferences.columnWidthRange.upperBound)
    }
}
