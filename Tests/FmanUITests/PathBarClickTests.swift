import AppKit
import Testing
@testable import FmanCore
@testable import FmanUI

@MainActor
@Suite(.serialized) struct PathBarClickTests {
    let fx = Fixture()

    init() { fx.dir("assets/downloads") }

    var folder: URL { fx.url.appendingPathComponent("assets/downloads") }

    func window() -> MainWindowController {
        let wc = makeWindow([folder, fx.url])
        wc.window!.layoutIfNeeded()
        return wc
    }

    func click(_ header: PaneHeaderView, atX x: CGFloat) {
        let p = header.convert(NSPoint(x: x, y: header.bounds.midY), to: nil)
        let e = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: 0,
                                   windowNumber: header.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        header.mouseDown(with: e)
    }

    func segments(_ pane: PaneViewController) -> [PathBarView.SegmentButton] {
        func walk(_ v: NSView) -> [PathBarView.SegmentButton] {
            (v as? PathBarView.SegmentButton).map { [$0] } ?? v.subviews.flatMap(walk)
        }
        return walk(pane.header.pathBar)
    }

    @Test func clickingBlankPathSpaceEditsTheFullPathSelected() throws {
        let wc = window()
        let pane = wc.paneGroup.activePane
        let header = pane.header
        // Just left of the sort button: blank space after the breadcrumbs.
        click(header, atX: header.accessoryStack.frame.minX - 20)
        #expect(header.isEditingPath)
        let editor = try #require(wc.window!.firstResponder as? NSTextView)
        #expect(header.pathField.stringValue == folder.path)
        #expect(editor.selectedRange() == NSRange(location: 0, length: (folder.path as NSString).length), "all selected, ready to copy")
        _ = header.control(header.pathField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(!header.isEditingPath)
        #expect(pane.browser.hasFocus)
    }

    @Test func clickingTheCurrentFolderSegmentEditsParentSegmentsNavigate() throws {
        let wc = window()
        let pane = wc.paneGroup.activePane
        let segs = segments(pane)
        let last = try #require(segs.last)
        #expect(last.url.lastPathComponent == "downloads")
        last.performClick(nil)
        #expect(pane.header.isEditingPath)
        pane.header.endPathEditing()
        let parent = try #require(segs.first { $0.url.lastPathComponent == "assets" })
        parent.performClick(nil)
        #expect(!pane.header.isEditingPath)
        #expect(pane.currentDirectory.lastPathComponent == "assets")
    }

    @Test func clickingTheSortButtonDoesNotEdit() {
        let wc = window()
        let header = wc.paneGroup.activePane.header
        click(header, atX: header.accessoryStack.frame.midX)
        #expect(!header.isEditingPath)
    }
}
