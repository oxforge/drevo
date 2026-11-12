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

    // MARK: Stopping the folder walk

    /// What a stand-in for the folder walk saw, shared with the background thread.
    final class Walk: @unchecked Sendable {
        private let lock = NSLock()
        private var _started = false, _stopped = false
        var started: Bool { lock.lock(); defer { lock.unlock() }; return _started }
        var stopped: Bool { lock.lock(); defer { lock.unlock() }; return _stopped }

        /// Runs until it is told to stop (or 10 s, so a failing test still ends).
        func run(isCancelled: () -> Bool) -> Int64 {
            lock.lock(); _started = true; lock.unlock()
            let limit = Date().addingTimeInterval(10)
            while !isCancelled(), Date() < limit { usleep(2000) }
            if isCancelled() { lock.lock(); _stopped = true; lock.unlock() }
            return 0
        }
    }

    func summaryPreview(walk: Walk) -> FilePreviewView {
        let items = ["Folder", "Level0"].map { try! FileItem(url: url($0)) }
        let preview = FilePreviewView(items: items, relativeDates: false)
        preview.measureFolder = { _, isCancelled in walk.run(isCancelled: isCancelled) }
        return preview
    }

    @Test func removedPreviewStopsItsMeasurement() {
        let walk = Walk()
        let preview = summaryPreview(walk: walk)
        let host = NSView()
        host.addSubview(preview)
        #expect(waitFor { walk.started })
        #expect(preview.sizeLabel.stringValue == "Calculating…")
        preview.removeFromSuperview()
        #expect(waitFor { walk.stopped }, "the walk ends when the preview is removed")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(preview.sizeLabel.stringValue == "Calculating…", "a stopped walk shows no total")
    }

    @Test func previewRemovedRightAwayNeverStartsMeasuring() {
        let walk = Walk()
        let preview = summaryPreview(walk: walk)
        let host = NSView()
        host.addSubview(preview)
        preview.removeFromSuperview()
        RunLoop.main.run(until: Date().addingTimeInterval(FilePreviewView.measureDelay + 0.3))
        #expect(!walk.started, "replaced before the delay: no walk at all")
    }

    @Test func previewThatWasNeverShownDoesNotMeasure() {
        let walk = Walk()
        let preview = summaryPreview(walk: walk)
        RunLoop.main.run(until: Date().addingTimeInterval(FilePreviewView.measureDelay + 0.3))
        #expect(!walk.started)
        #expect(preview.measurement == nil)
    }

    @Test func deallocatedPreviewStopsItsMeasurement() {
        let walk = Walk()
        var host: NSView? = NSView()
        autoreleasepool {
            host?.addSubview(summaryPreview(walk: walk))
            #expect(waitFor { walk.started })
            host = nil // the whole hierarchy goes away without the preview being removed first
        }
        #expect(waitFor { walk.stopped })
    }

    @Test func selectingSomethingElseStopsTheWalkOfTheOldPreview() throws {
        let wc = makeWindow([fx.url, fx.url], modes: [.columns, .columns])
        let cb = columns(wc)
        cb.select([url("Folder"), url("c.zip")])
        let old = try #require(cb.preview)
        let token = try #require(old.measurement, "a walk is scheduled as soon as the preview is in the pane")
        cb.select([url("Folder"), url("Level0")])
        #expect(cb.preview !== old)
        #expect(token.isCancelled)
        #expect(old.measurement == nil)
    }

    @Test func previewPutBackMeasuresAgain() {
        let items = ["Folder", "c.zip"].map { try! FileItem(url: url($0)) }
        let preview = FilePreviewView(items: items, relativeDates: false)
        let host = NSView()
        host.addSubview(preview)
        preview.removeFromSuperview()
        host.addSubview(preview)
        #expect(waitFor { preview.sizeLabel.stringValue == Formatting.size(2250) })
        #expect(preview.measurement == nil, "nothing left to stop once the total is shown")
    }

    @Test func closingTheInfoPanelStopsItsMeasurement() {
        let panel = InfoPanel(url: url("Folder"), relativeDates: false)
        #expect(!panel.measurement.isCancelled)
        panel.window?.close()
        #expect(panel.measurement.isCancelled)
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
