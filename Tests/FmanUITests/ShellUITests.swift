import AppKit
import Testing
@testable import FmanCore
@testable import FmanUI

@MainActor
@Suite(.serialized) struct ShellUITests {
    let fx = Fixture()
    let opener = RecordingOpener()

    init() {
        fx.file("it's here.txt", "x")
        fx.dir("Sub")
    }

    func window() -> MainWindowController {
        let wc = makeWindow([fx.url, fx.url], env: testEnvironment(trash: fx.url.appendingPathComponent(".T"), opener: opener))
        wc.shell.shellOverride = ("/bin/zsh", ["-f"]) // never run the user's rc files in tests
        return wc
    }

    /// Spins the run loop until `condition` holds (output arrives asynchronously).
    func waitFor(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    @Test func bangFocusesCommandLine() {
        let wc = window()
        let w = wc.window!
        press(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: w.windowNumber,
                               context: nil, characters: "!", charactersIgnoringModifiers: "!", isARepeat: false, keyCode: KeyCode.one)!, in: w)
        #expect(wc.commandBar.hasFocus)
        #expect(wc.commandBar.field.stringValue.isEmpty, "the ! itself isn't typed")
    }

    @Test func runsInActiveFolderAndRefreshesPanes() {
        let wc = window()
        wc.commandBar.field.stringValue = "pwd; touch made-by-shell.txt"
        wc.commandBar.submit(inTerminal: false)
        #expect(wc.workspace.isConsoleVisible)
        #expect(waitFor { !wc.shell.isRunning && wc.workspace.console.transcript.contains("exit 0") })
        #expect(wc.workspace.console.transcript.contains(fx.url.lastPathComponent))
        #expect(waitFor { wc.paneGroup.activePane.browser.visibleItems.contains { $0.name == "made-by-shell.txt" } })
        #expect(wc.env.preferences.commandHistory.last == "pwd; touch made-by-shell.txt")
    }

    @Test func stopInterruptsLongCommand() {
        let wc = window()
        wc.commandBar.field.stringValue = "sleep 30"
        wc.commandBar.submit(inTerminal: false)
        #expect(waitFor { wc.shell.isRunning })
        #expect(wc.canPerform(.stopCommand))
        let start = Date()
        wc.perform(.stopCommand)
        #expect(waitFor(5) { !wc.shell.isRunning })
        #expect(Date().timeIntervalSince(start) < 4)
    }

    @Test func historyAndSelectionInsertion() throws {
        let wc = window()
        wc.env.preferences.commandHistory = ["ls -la", "git status"]
        wc.paneGroup.activePane.browser.select([fx.url.appendingPathComponent("it's here.txt")])
        wc.commandBar.focus()
        let editor = try #require(wc.window!.firstResponder as? NSTextView)
        _ = wc.commandBar.control(wc.commandBar.field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:)))
        #expect(wc.commandBar.field.stringValue == "git status")
        _ = wc.commandBar.control(wc.commandBar.field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:)))
        #expect(wc.commandBar.field.stringValue == "ls -la")
        _ = wc.commandBar.control(wc.commandBar.field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
        _ = wc.commandBar.control(wc.commandBar.field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
        #expect(wc.commandBar.field.stringValue == "")
        editor.string = "cat"
        editor.selectedRange = NSRange(location: 3, length: 0)
        wc.commandBar.insertSelection(fullPaths: false)
        #expect(wc.commandBar.field.stringValue == "cat 'it'\\''s here.txt' ")
    }

    @Test func escapeReturnsToPane() throws {
        let wc = window()
        wc.commandBar.focus()
        let editor = try #require(wc.window!.firstResponder as? NSTextView)
        _ = wc.commandBar.control(wc.commandBar.field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(wc.paneGroup.activePane.browser.hasFocus)
    }

    @Test func openTerminalUsesSelectedFolder() {
        let wc = window()
        wc.paneGroup.activePane.browser.select([fx.url.appendingPathComponent("Sub")])
        wc.perform(.openTerminal)
        #expect(opener.opened.last?.map(\.lastPathComponent) == ["Sub"])
    }

    @Test func runInTerminalWritesSelfDeletingScript() throws {
        let wc = window()
        wc.commandBar.field.stringValue = "echo 'hi'"
        wc.commandBar.submit(inTerminal: true)
        let script = try #require(opener.opened.last?.first)
        defer { try? FileManager.default.removeItem(at: script) }
        #expect(script.pathExtension == "command")
        let text = try String(contentsOf: script, encoding: .utf8)
        #expect(text.contains("cd '\(fx.url.path)'"))
        #expect(text.contains("rm -f \"$0\""))
        #expect(text.contains("echo '\\''hi'\\''"))
        let perms = try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o700)
    }

    @Test func scriptRunsCommandThenStaysInteractive() throws {
        // Run the generated script with sh, with the "interactive shell" swapped for `true`
        // so it exits: proves quoting survives a real shell.
        let text = TerminalLauncher.scriptText(command: "echo \"$((1+2))\" 'x y' > out.txt", folder: fx.url, shell: "/bin/zsh")
            .replacingOccurrences(of: "rm -f \"$0\"\n", with: "")
            .replacingOccurrences(of: "exec '/bin/zsh' -l -i -c", with: "exec /bin/zsh -f -c")
            .replacingOccurrences(of: "exec '\\''/bin/zsh'\\'' -l -i", with: "exit 0")
        let script = fx.url.appendingPathComponent("t.sh")
        try text.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path]
        try p.run()
        p.waitUntilExit()
        #expect(try String(contentsOf: fx.url.appendingPathComponent("out.txt"), encoding: .utf8) == "3 x y\n")
    }
}
