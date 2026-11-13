import AppKit
import Testing
@testable import DrevoCore
@testable import DrevoUI

@MainActor
@Suite(.serialized) struct PaneWidthTests {
    let fx = Fixture()

    func split(_ wc: MainWindowController) -> PaneSplitView { wc.paneGroup.view as! PaneSplitView }

    func widths(_ wc: MainWindowController) -> [CGFloat] {
        wc.window!.layoutIfNeeded()
        return wc.paneGroup.panes.map { $0.view.frame.width }
    }

    @Test func commandMakesPanesEqualAgain() {
        let wc = makeWindow([fx.url, fx.url])
        split(wc).setPosition(300, ofDividerAt: 0)
        let uneven = widths(wc)
        #expect(abs(uneven[0] - uneven[1]) > 50)
        #expect(wc.canPerform(.equalizePanes))
        #expect(wc.perform(.equalizePanes))
        let even = widths(wc)
        #expect(abs(even[0] - even[1]) <= 1)
    }

    @Test func doubleClickOnTheDividerMakesPanesEqual() {
        let wc = makeWindow([fx.url, fx.url])
        let split = split(wc)
        split.setPosition(300, ofDividerAt: 0)
        wc.window!.layoutIfNeeded()
        let onDivider = split.convert(NSPoint(x: wc.paneGroup.panes[0].view.frame.maxX, y: split.bounds.midY), to: nil)
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: onDivider, modifierFlags: [], timestamp: 0,
                                       windowNumber: wc.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!
        split.mouseDown(with: click)
        let even = widths(wc)
        #expect(abs(even[0] - even[1]) <= 1)
        #expect(!split.isOnDivider(NSPoint(x: 40, y: split.bounds.midY)))
    }

    @Test func aSinglePaneHasNothingToEqualize() {
        let wc = makeWindow([fx.url], modes: [.list])
        #expect(!wc.canPerform(.equalizePanes))
    }
}
