import AppKit
import Testing
@testable import FmanCore
@testable import FmanUI

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
