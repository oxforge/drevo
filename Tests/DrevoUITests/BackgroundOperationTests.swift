import AppKit
import Testing
@testable import DrevoCore
@testable import DrevoUI

/// Duplicate, Delete Immediately, undo and redo as background jobs (other tests run
/// them inline): each is listed while it runs, finishes through the main run loop, and
/// undo keeps its order.
@MainActor
@Suite(.serialized) struct BackgroundOperationTests {
    let fx = Fixture()
    let prompts = ScriptedPrompts()
    var left: URL { fx.url.appendingPathComponent("left") }
    var right: URL { fx.url.appendingPathComponent("right") }

    init() {
        fx.file("left/a.txt", "A")
        fx.file("left/b.txt", "B")
        fx.file("left/c.txt", "C")
        fx.dir("right")
    }

    func window() -> MainWindowController {
        let env = testEnvironment(trash: fx.url.appendingPathComponent("_trash"), prompts: prompts)
        env.preferences.confirmTransfers = false
        return makeWindow([left, right], env: env)
    }

    func exists(_ path: String) -> Bool { FileIdentity.exists(fx.url.appendingPathComponent(path)) }
    func selected(_ pane: PaneViewController) -> [String] { pane.selectedItems.map(\.name) }

    /// Spins the main run loop until no job is left.
    func finishJobs(_ ops: OperationsCenter) {
        let end = Date().addingTimeInterval(10)
        while !ops.jobs.isEmpty, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        #expect(ops.jobs.isEmpty)
    }

    /// Lets the undo group of the last operation close, as between two user events.
    func nextEvent() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

    @Test func duplicateRunsAsAJobAndSelectsTheCopy() {
        let wc = window()
        let ops = wc.env.operations
        ops.runTransfersSynchronously = false
        let pane = wc.paneGroup.activePane
        pane.browser.select([left.appendingPathComponent("a.txt")])
        wc.perform(.duplicate)
        #expect(ops.jobs.map(\.title) == ["Duplicating “a.txt”"])
        finishJobs(ops)
        #expect(exists("left/a copy.txt"))
        #expect(selected(pane) == ["a copy.txt"])
        #expect(ops.undoManager.undoMenuItemTitle == "Undo Duplicate")
        #expect(prompts.conflicts.isEmpty && prompts.errors.isEmpty)
    }

    @Test func deleteRunsAsAJobAndSelectsTheNextRow() {
        let wc = window()
        let ops = wc.env.operations
        ops.runTransfersSynchronously = false
        let pane = wc.paneGroup.activePane
        pane.browser.select([left.appendingPathComponent("a.txt"), left.appendingPathComponent("b.txt")])
        wc.perform(.deleteImmediately)
        #expect(ops.jobs.map(\.title) == ["Deleting 2 items"])
        finishJobs(ops)
        #expect(!exists("left/a.txt"))
        #expect(!exists("left/b.txt"))
        #expect(!exists("_trash/a.txt"), "deleted, not trashed")
        #expect(selected(pane) == ["c.txt"])
        #expect(!ops.undoManager.canUndo, "there is no undo for a permanent delete")
    }

    @Test func aStoppedDeleteKeepsTheRestAndShowsNoError() {
        for i in 0..<3000 { fx.file("left/Big/f\(i).txt") }
        let wc = window()
        let ops = wc.env.operations
        ops.runTransfersSynchronously = false
        let pane = wc.paneGroup.activePane
        pane.browser.select([left.appendingPathComponent("Big")])
        wc.perform(.deleteImmediately)
        ops.jobs.first?.cancel() // the Stop button
        finishJobs(ops)
        #expect(exists("left/Big"), "what wasn't deleted yet stays")
        #expect(prompts.errors.isEmpty)
        #expect(selected(pane) == ["Big"], "the selection isn't moved off an item that is still there")
    }

    @Test func undoAndRedoRunAsJobsAndKeepTheirNames() {
        let wc = window()
        let ops = wc.env.operations
        wc.paneGroup.activePane.browser.select([left.appendingPathComponent("b.txt")])
        wc.perform(.moveToOtherPane)
        #expect(exists("right/b.txt"))

        ops.runTransfersSynchronously = false
        ops.undoManager.undo()
        #expect(ops.jobs.map(\.title) == ["Undoing Move"])
        #expect(!ops.undoManager.canUndo && !ops.undoManager.canRedo, "nothing more until this one has finished")
        finishJobs(ops)
        #expect(exists("left/b.txt"))
        #expect(!exists("right/b.txt"))
        #expect(wc.paneGroup.panes[0].browser.visibleItems.map(\.name).contains("b.txt"), "the panes were refreshed")
        #expect(ops.undoManager.canRedo)
        #expect(ops.undoManager.redoMenuItemTitle == "Redo Move")

        ops.undoManager.redo()
        #expect(ops.jobs.map(\.title) == ["Redoing Move"])
        finishJobs(ops)
        #expect(exists("right/b.txt"))
        #expect(!ops.undoManager.canRedo)
        #expect(ops.undoManager.undoMenuItemTitle == "Undo Move")
    }

    /// A second ⌘Z while the first still runs must not start early or be lost for later.
    @Test func undoKeepsItsOrderWhileOneIsRunning() {
        let wc = window()
        let ops = wc.env.operations
        let pane = wc.paneGroup.activePane
        pane.browser.select([left.appendingPathComponent("a.txt")])
        wc.perform(.moveToOtherPane)
        nextEvent()
        pane.browser.select([left.appendingPathComponent("b.txt")])
        wc.perform(.moveToTrash)
        nextEvent()

        ops.runTransfersSynchronously = false
        ops.undoManager.undo()
        ops.undoManager.undo() // pressed again before the first has finished
        #expect(ops.jobs.map(\.title) == ["Undoing Move to Trash"])
        finishJobs(ops)
        #expect(exists("left/b.txt"), "the last operation was undone")
        #expect(exists("right/a.txt"), "the one before it wasn't, yet")
        #expect(ops.undoManager.undoMenuItemTitle == "Undo Move")
        #expect(ops.undoManager.redoMenuItemTitle == "Redo Move to Trash")

        ops.undoManager.undo()
        finishJobs(ops)
        #expect(exists("left/a.txt"))
        #expect(!ops.undoManager.canUndo)

        ops.undoManager.redo()
        finishJobs(ops)
        #expect(exists("right/a.txt"), "redo goes in the opposite order")
        #expect(exists("left/b.txt"))
        ops.undoManager.redo()
        finishJobs(ops)
        #expect(!exists("left/b.txt"))
        #expect(!ops.undoManager.canRedo)
    }

    /// What was reversed before the failure stays redoable, under the same name.
    @Test func aPartlyFailedUndoIsReportedAndStaysRedoable() {
        let wc = window()
        let ops = wc.env.operations
        wc.paneGroup.activePane.browser.select([left.appendingPathComponent("a.txt"), left.appendingPathComponent("b.txt")])
        wc.perform(.moveToOtherPane)
        fx.file("left/a.txt", "squatter") // a.txt can't go back

        ops.runTransfersSynchronously = false
        ops.undoManager.undo()
        finishJobs(ops)
        #expect(prompts.errors.count == 1)
        #expect(prompts.errors.first?.hasPrefix("Couldn’t completely undo Move.") == true)
        #expect(exists("left/b.txt"))
        #expect(exists("right/a.txt"))
        #expect(ops.undoManager.redoMenuItemTitle == "Redo Move")

        ops.undoManager.redo()
        finishJobs(ops)
        #expect(exists("right/b.txt"), "the reversed part was redone")
    }

    /// Nothing was reversed, so no "Redo" is left behind that would do nothing.
    @Test func anUndoThatFailsEntirelyLeavesNoRedo() {
        let wc = window()
        let ops = wc.env.operations
        wc.paneGroup.activePane.browser.select([left.appendingPathComponent("a.txt")])
        wc.perform(.moveToOtherPane)
        fx.file("left/a.txt", "squatter")

        ops.runTransfersSynchronously = false
        ops.undoManager.undo()
        #expect(!ops.undoManager.canRedo, "not while it runs")
        finishJobs(ops)
        #expect(prompts.errors.count == 1)
        #expect(prompts.errors.first?.hasPrefix("Couldn’t undo Move.") == true)
        #expect(!ops.undoManager.canRedo)
        #expect(!ops.undoManager.canUndo)
        #expect(exists("right/a.txt"))
    }

    /// The same, run inline: the redo is never registered in the first place.
    @Test func anInlineUndoThatFailsEntirelyLeavesNoRedo() {
        let wc = window()
        let ops = wc.env.operations
        wc.paneGroup.activePane.browser.select([left.appendingPathComponent("a.txt")])
        wc.perform(.moveToOtherPane)
        fx.file("left/a.txt", "squatter")
        ops.undoManager.undo()
        #expect(prompts.errors.count == 1)
        #expect(!ops.undoManager.canRedo)
    }
}
