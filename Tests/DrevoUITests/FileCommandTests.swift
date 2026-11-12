import AppKit
import Testing
@testable import DrevoCore
@testable import DrevoUI

@MainActor
@Suite(.serialized) struct FileCommandTests {
    let fx = Fixture()
    let prompts = ScriptedPrompts()
    var trash: URL { fx.url.appendingPathComponent("_trash") }
    var left: URL { fx.url.appendingPathComponent("left") }
    var right: URL { fx.url.appendingPathComponent("right") }

    init() {
        fx.file("left/a.txt", "A")
        fx.file("left/b.txt", "B")
        fx.dir("left/Folder")
        fx.dir("right")
    }

    func window() -> MainWindowController {
        let env = testEnvironment(trash: trash, prompts: prompts)
        env.preferences.confirmTransfers = false
        return makeWindow([left, right], env: env)
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: fx.url.appendingPathComponent(path).path) }
    func names(_ pane: PaneViewController) -> [String] { pane.browser.visibleItems.map(\.name) }

    @Test func f5CopiesToOtherPaneAndSelectsResult() {
        let wc = window()
        let w = wc.window!
        wc.paneGroup.activePane.browser.select([left.appendingPathComponent("a.txt")])
        press(key(KeyCode.f5, String(UnicodeScalar(NSF5FunctionKey)!), .function, window: w), in: w)
        #expect(exists("right/a.txt"))
        #expect(exists("left/a.txt"))
        #expect(wc.paneGroup.panes[1].selectedItems.map(\.name) == ["a.txt"])
        #expect(wc.paneGroup.activePane === wc.paneGroup.panes[0], "focus stays in the source pane")
    }

    /// The destination is typed as a path through a symlink; the pane shows the folder itself.
    @Test func f5ThroughASymlinkedPathSelectsTheResultInThePaneShowingTheFolder() {
        let link = fx.url.appendingPathComponent("link")
        try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: right)
        let wc = window()
        wc.env.preferences.confirmTransfers = true
        prompts.typedDestination = link.path
        wc.paneGroup.activePane.browser.select([left.appendingPathComponent("a.txt")])
        wc.perform(.copyToOtherPane)
        #expect(exists("right/a.txt"))
        #expect(wc.paneGroup.panes[1].currentDirectory.path == right.path)
        #expect(wc.paneGroup.panes[1].selectedItems.map(\.name) == ["a.txt"])
    }

    /// The background path of a transfer (tests otherwise run them inline): progress and
    /// the result arrive through the main run loop, where a test that spins it sees them.
    @Test func aBackgroundTransferFinishesOnTheMainRunLoop() {
        let wc = window()
        let ops = wc.env.operations
        ops.runTransfersSynchronously = false
        var jobUpdates = 0
        let observer = NotificationCenter.default.addObserver(forName: OperationsCenter.jobsDidChange, object: ops, queue: nil) { _ in
            MainActor.assumeIsolated { jobUpdates += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        var result: TransferResult?
        var finishedOnMain = false
        ops.transfer(.copy, [left.appendingPathComponent("a.txt"), left.appendingPathComponent("Folder")], to: right, window: nil) { r in
            finishedOnMain = Thread.isMainThread
            result = r
        }
        #expect(ops.jobs.count == 1)
        #expect(result == nil, "runs in the background")
        let end = Date().addingTimeInterval(10)
        while result == nil, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        #expect(finishedOnMain)
        #expect(result?.outputs.map(\.lastPathComponent) == ["a.txt", "Folder"])
        #expect(ops.jobs.isEmpty)
        #expect(jobUpdates >= 3, "the job was added, made progress and was removed")
        #expect(exists("right/a.txt"))
        #expect(names(wc.paneGroup.panes[1]) == ["Folder", "a.txt"], "the panes were refreshed")
    }

    @Test func f6MovesAndUndoMovesBack() {
        let wc = window()
        wc.paneGroup.activePane.browser.select([left.appendingPathComponent("b.txt")])
        wc.perform(.moveToOtherPane)
        #expect(exists("right/b.txt"))
        #expect(!exists("left/b.txt"))
        #expect(names(wc.paneGroup.panes[0]) == ["Folder", "a.txt"])
        wc.env.operations.undoManager.undo()
        #expect(exists("left/b.txt"))
        #expect(!exists("right/b.txt"))
        #expect(names(wc.paneGroup.panes[1]).isEmpty)
        wc.env.operations.undoManager.redo()
        #expect(exists("right/b.txt"))
    }

    @Test func confirmationSheetProposesTargetFolder() {
        let wc = window()
        wc.env.preferences.confirmTransfers = true
        let other = fx.dir("elsewhere")
        prompts.destination = .some(other)
        wc.paneGroup.activePane.browser.select([left.appendingPathComponent("a.txt")])
        wc.perform(.copyToOtherPane)
        #expect(prompts.askedDestination?.standardizedFileURL.path == right.standardizedFileURL.path)
        #expect(exists("elsewhere/a.txt"))
        prompts.destination = .some(nil)
        wc.perform(.copyToOtherPane)
        #expect(!exists("right/a.txt"), "cancelled")
    }

    @Test func conflictAsksAndKeepsBoth() {
        fx.file("right/a.txt", "old")
        let wc = window()
        wc.paneGroup.activePane.browser.select([left.appendingPathComponent("a.txt")])
        wc.perform(.copyToOtherPane)
        #expect(prompts.conflicts.count == 1)
        #expect(exists("right/a 2.txt"))
    }

    @Test func newFolderThenRenameInPlace() throws {
        let wc = window()
        let w = wc.window!
        let pane = wc.paneGroup.activePane
        wc.perform(.newFolder)
        #expect(exists("left/untitled folder"))
        // Typing the name happens in later events; let the undo group for "New Folder" close.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let editor = try #require(w.firstResponder as? NSTextView, "name field is being edited")
        #expect(editor.string == "untitled folder")
        editor.string = "Photos"
        w.makeFirstResponder(pane.browser.activeTableView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(exists("left/Photos"))
        #expect(!exists("left/untitled folder"))
        #expect(pane.selectedItems.map(\.name) == ["Photos"])
        // Undo the rename, then the creation.
        wc.env.operations.undoManager.undo()
        #expect(exists("left/untitled folder"))
        wc.env.operations.undoManager.undo()
        #expect(!exists("left/untitled folder"))
    }

    @Test func renameSelectsBaseNameAndEscCancels() throws {
        let wc = window()
        let w = wc.window!
        let pane = wc.paneGroup.activePane
        pane.browser.select([left.appendingPathComponent("a.txt")])
        wc.perform(.rename)
        let editor = try #require(w.firstResponder as? NSTextView)
        #expect(editor.selectedRange() == NSRange(location: 0, length: 1), "extension isn't selected")
        editor.string = "zzz.txt"
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(exists("left/a.txt"))
        #expect(!exists("left/zzz.txt"))
    }

    @Test func renameToTakenNameReportsError() throws {
        let wc = window()
        let w = wc.window!
        let pane = wc.paneGroup.activePane
        pane.browser.select([left.appendingPathComponent("a.txt")])
        wc.perform(.rename)
        let editor = try #require(w.firstResponder as? NSTextView)
        editor.string = "b.txt"
        w.makeFirstResponder(pane.browser.activeTableView)
        #expect(prompts.errors.count == 1)
        #expect(exists("left/a.txt"))
    }

    @Test func trashSelectsNextAndUndoPutsBack() {
        let wc = window()
        let pane = wc.paneGroup.activePane
        pane.browser.select([left.appendingPathComponent("a.txt")])
        wc.perform(.moveToTrash)
        #expect(!exists("left/a.txt"))
        #expect(exists("_trash/a.txt"))
        #expect(pane.selectedItems.map(\.name) == ["b.txt"])
        wc.env.operations.undoManager.undo()
        #expect(exists("left/a.txt"))
    }

    @Test func deleteImmediatelyNeedsConfirmation() {
        let wc = window()
        let pane = wc.paneGroup.activePane
        pane.browser.select([left.appendingPathComponent("a.txt")])
        prompts.deleteAnswer = false
        wc.perform(.deleteImmediately)
        #expect(exists("left/a.txt"))
        prompts.deleteAnswer = true
        wc.perform(.deleteImmediately)
        #expect(!exists("left/a.txt"))
        #expect(!exists("_trash/a.txt"))
    }

    @Test func copyPasteAndCutPaste() {
        let wc = window()
        let (l, r) = (wc.paneGroup.panes[0], wc.paneGroup.panes[1])
        l.browser.select([left.appendingPathComponent("a.txt")])
        l.copy(nil)
        r.paste(nil)
        #expect(exists("right/a.txt"))
        #expect(exists("left/a.txt"))
        l.browser.select([left.appendingPathComponent("b.txt")])
        l.cut(nil)
        r.paste(nil)
        #expect(exists("right/b.txt"))
        #expect(!exists("left/b.txt"))
        // A second paste after a cut copies (the cut is used up) — nothing left to move.
        #expect(wc.env.pasteboard !== NSPasteboard.general)
    }

    @Test func duplicateAndCopyPath() {
        let wc = window()
        let pane = wc.paneGroup.activePane
        pane.browser.select([left.appendingPathComponent("a.txt")])
        wc.perform(.duplicate)
        #expect(exists("left/a copy.txt"))
        #expect(pane.selectedItems.map(\.name) == ["a copy.txt"])
        wc.perform(.copyPath)
        #expect(wc.env.pasteboard.string(forType: .string)?.hasSuffix("/left/a copy.txt") == true)
    }

    @Test func fileCommandsDisabledWhileEditingText() throws {
        let wc = window()
        let pane = wc.paneGroup.activePane
        pane.browser.select([left.appendingPathComponent("a.txt")])
        wc.perform(.rename)
        let item = MainMenu.item(for: .moveToTrash, keyMap: wc.env.keyMap)
        #expect(!wc.validateMenuItem(item))
        wc.window!.makeFirstResponder(pane.browser.activeTableView)
        #expect(wc.validateMenuItem(item))
    }
}
