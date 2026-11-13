import AppKit
import Foundation
import Testing
@testable import DrevoCore
@testable import DrevoUI

/// A second ⌘/⌃/F-key for a command works wherever its menu key would: the menu carries
/// only the first one, so the window runs the others when no menu item claims them.
@MainActor
@Suite(.serialized) struct ExtraKeyTests {
    let fx = Fixture()

    enum Code { static let k: UInt16 = 40, escape: UInt16 = 53 }

    func window(extra: [CommandID: [String]]) throws -> MainWindowController {
        fx.file("one.txt")
        fx.file("two.txt")
        fx.dir("beta")
        // The scratch shell folder goes next to the trash: keep both out of the listing.
        let env = testEnvironment(trash: fx.url.appendingPathComponent(".T/trash"))
        try env.saveKeyChanges(extra.mapValues { $0.map { try! KeyCombo(parsing: $0) } })
        return makeWindow([fx.url, fx.url.appendingPathComponent("beta")], env: env)
    }

    /// What reaches the window after the main menu didn't claim the key.
    func unclaimed(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags, in wc: MainWindowController) {
        wc.window!.sendEvent(key(code, chars, flags, window: wc.window!))
    }

    @Test func anExtraKeyForAShellCommandWorksWhileTyping() throws {
        let wc = try window(extra: [.toggleConsole: ["opt+cmd+j", "cmd+k"]])
        wc.commandBar.focus()
        #expect(wc.commandBar.hasFocus)
        let shown = wc.workspace.isConsoleVisible
        unclaimed(Code.k, "k", .command, in: wc)
        #expect(wc.workspace.isConsoleVisible != shown)
    }

    @Test func anExtraKeyForAFileCommandLeavesTextFieldsAlone() throws {
        let wc = try window(extra: [.swapPanes: ["cmd+u", "cmd+k"]])
        let first = wc.paneGroup.panes[0]
        wc.commandBar.focus()
        unclaimed(Code.k, "k", .command, in: wc)
        #expect(first.currentDirectory.lastPathComponent != "beta", "file commands are off while a text field edits")
        #expect(wc.commandBar.hasFocus)

        wc.paneGroup.activePane.focus()
        unclaimed(Code.k, "k", .command, in: wc)
        #expect(first.currentDirectory.lastPathComponent == "beta")
    }

    @Test func anExtraSelectAllKeyWorksInTextFieldsAndTheFileList() throws {
        let wc = try window(extra: [.selectAll: ["cmd+a", "ctrl+cmd+k"]])
        wc.commandBar.field.stringValue = "hello"
        wc.commandBar.focus()
        let editor = try #require(wc.window!.firstResponder as? NSTextView)
        #expect(editor.selectedRange == NSRange(location: 5, length: 0))
        unclaimed(Code.k, "k", [.control, .command], in: wc)
        #expect(editor.selectedRange == NSRange(location: 0, length: 5))

        let pane = wc.paneGroup.panes[0]
        pane.focus()
        unclaimed(Code.k, "k", [.control, .command], in: wc)
        #expect(Set(pane.selectedItems.map(\.name)) == ["beta", "one.txt", "two.txt"])
    }

    @Test func escWithModifiersReachesTheKeyMapWhileFiltering() throws {
        let wc = try window(extra: [.swapPanes: ["cmd+u", "opt+escape"]])
        let first = wc.paneGroup.panes[0]
        first.typeIntoFilter("o")
        #expect(first.filter == "o")
        press(key(Code.escape, "\u{1b}", .option, window: wc.window!), in: wc.window!)
        #expect(first.currentDirectory.lastPathComponent == "beta")
    }

    @Test func bareEscStillClearsTheFilter() throws {
        let wc = try window(extra: [.swapPanes: ["cmd+u", "opt+escape"]])
        let first = wc.paneGroup.panes[0]
        first.typeIntoFilter("o")
        press(key(Code.escape, "\u{1b}", [], window: wc.window!), in: wc.window!)
        #expect(first.filter.isEmpty)
        #expect(first.currentDirectory.lastPathComponent != "beta")
    }
}
