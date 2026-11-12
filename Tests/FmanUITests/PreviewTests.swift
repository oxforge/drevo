import AppKit
import Testing
@testable import FmanCore
@testable import FmanUI

@MainActor
@Suite(.serialized) struct PreviewTests {
    let fx = Fixture()

    init() {
        fx.file("a.zip", String(repeating: "a", count: 1000))
        fx.file("b.jpeg", String(repeating: "b", count: 500))
        fx.file("c.zip", String(repeating: "c", count: 250))
        fx.dir("Folder")
        fx.file("Folder/inner.txt", String(repeating: "i", count: 2000))
        for i in 0..<12 { fx.dir("Level\(i)") }
    }

    func url(_ name: String) -> URL { fx.url.appendingPathComponent(name) }

    func columns(_ wc: MainWindowController) -> ColumnBrowserViewController {
        wc.paneGroup.activePane.browser as! ColumnBrowserViewController
    }

    func waitFor(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    @Test func severalFilesKeepThePreviewWithCountAndSize() throws {
        let wc = makeWindow([fx.url, fx.url], modes: [.columns, .columns])
        let cb = columns(wc)
        cb.select([url("a.zip")])
        #expect(cb.preview?.items.count == 1)
        cb.select([url("a.zip"), url("b.jpeg")])
        let preview = try #require(cb.preview, "the preview stays when a second file is selected")
        #expect(preview.titleLabel.stringValue == "2 items")
        #expect(preview.subtitleLabel.stringValue == "2 files")
        #expect(preview.sizeLabel.stringValue == Formatting.size(1500))
    }

    @Test func extendingTheSelectionDoesNotMoveTheColumns() throws {
        let wc = makeWindow([fx.url, fx.url], modes: [.columns, .columns])
        let cb = columns(wc)
        cb.select([url("a.zip")])
        cb.view.layoutSubtreeIfNeeded()
        let scroll = try #require(cb.view as? NSScrollView)
        let before = (scroll.contentView.bounds.origin, scroll.documentView?.frame.width)
        cb.select([url("a.zip"), url("b.jpeg")])
        cb.view.layoutSubtreeIfNeeded()
        #expect(scroll.contentView.bounds.origin == before.0)
        #expect(scroll.documentView?.frame.width == before.1)
    }

    @Test func foldersAreMeasuredInTheBackground() throws {
        let wc = makeWindow([fx.url, fx.url], modes: [.columns, .columns])
        let cb = columns(wc)
        cb.select([url("Folder"), url("c.zip")])
        let preview = try #require(cb.preview)
        #expect(preview.subtitleLabel.stringValue == "1 file, 1 folder")
        #expect(waitFor { preview.sizeLabel.stringValue == Formatting.size(2250) })
    }

    @Test func singleFolderStillOpensItsColumn() {
        let wc = makeWindow([fx.url, fx.url], modes: [.columns, .columns])
        let cb = columns(wc)
        cb.select([url("Folder")])
        #expect(cb.preview == nil)
        #expect(cb.columns.last?.directory.lastPathComponent == "Folder")
    }

    @Test func summaryText() {
        let items = ["x.zip", "y.zip", "z.jpeg"].map { FileItem(url: URL(fileURLWithPath: "/t/\($0)"), name: $0, isContainer: false, isDirectory: false,
                                                                  size: 1, kind: $0.hasSuffix("zip") ? "Zip archive" : "JPEG image") }
        #expect(FilePreviewView.kinds(items) == "Zip archive, JPEG image")
        #expect(FilePreviewView.breakdown(items) == "3 files")
        let more = items + ["a.md", "b.csv"].map { FileItem(url: URL(fileURLWithPath: "/t/\($0)"), name: $0, isContainer: false, isDirectory: false, kind: $0) }
        #expect(FilePreviewView.kinds(more) == "Zip archive, JPEG image +2 more")
    }
}
