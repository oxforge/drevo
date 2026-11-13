import AppKit
import Testing
@testable import DrevoCore
@testable import DrevoUI

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

    /// The shell ends on its own thread and the console catches up on the main thread
    /// later; until it has, the command still counts as running, so nothing reads a
    /// half-written transcript and no next command starts in between.
    @Test func runsUntilTheConsoleShowsTheEnd() throws {
        let wc = window()
        wc.commandBar.field.stringValue = "echo end-marker"
        wc.commandBar.submit(inTerminal: false)
        let command = try #require(wc.shell.running)
        #expect(command.waitUntilExit(timeout: 5), "the shell has exited; the main thread hasn't caught up")
        #expect(wc.shell.isRunning)
        #expect(!wc.shell.run("echo second", in: fx.url), "no second command before the first one's end is shown")
        #expect(waitFor { !wc.shell.isRunning })
        #expect(wc.workspace.console.transcript.contains("end-marker\n"))
        #expect(wc.workspace.console.transcript.contains("exit 0"))
        #expect(!wc.workspace.console.transcript.contains("echo second"))
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

    @Test func tabCompletesTheFileNameAndKeepsFocus() throws {
        let wc = window()
        wc.commandBar.focus()
        let editor = try #require(wc.window!.firstResponder as? NSTextView)
        editor.string = "cat it"
        editor.selectedRange = NSRange(location: 6, length: 0)
        let handled = wc.commandBar.control(wc.commandBar.field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:)))
        #expect(handled, "Tab must not move the focus to the next control")
        #expect(wc.commandBar.field.stringValue == "cat it\\'s\\ here.txt ")
        #expect(editor.selectedRange == NSRange(location: 20, length: 0))
        #expect(wc.commandBar.hasFocus)
        #expect(wc.commandBar.control(wc.commandBar.field, textView: editor, doCommandBy: #selector(NSResponder.insertBacktab(_:))),
                "Shift-Tab stays in the command line as well")
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
        #expect(script.isInside(fx.url), "the test environment's scratch folder, never the user's Caches")
        #expect(script.pathExtension == "command")
        let text = try String(contentsOf: script, encoding: .utf8)
        #expect(text.contains("cd '\(fx.url.path)'"))
        #expect(text.contains("rm -f \"$0\""))
        #expect(text.contains("echo '\\''hi'\\''"))
        let perms = try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o700)
    }

    @Test func scriptRunsCommandThenStaysInteractive() throws {
        // Run the generated script with sh, with the "interactive shell" swapped for `exit 0`
        // so it exits: proves quoting survives a real shell. Each swap must find its text:
        // a missed one would run `zsh -l -i`, which reads the user's rc files.
        var text = TerminalLauncher.scriptText(command: "echo \"$((1+2))\" 'x y' > out.txt", folder: fx.url, shell: "/bin/zsh")
        for (pattern, replacement) in [
            ("rm -f \"$0\"\n", ""),
            ("exec '/bin/zsh' -l -i -c", "exec /bin/zsh -f -c"),
            ("exec '\\''/bin/zsh'\\'' -l -i", "exit 0"),
        ] {
            try #require(text.contains(pattern), "the script format changed: no \(pattern)")
            text = text.replacingOccurrences(of: pattern, with: replacement)
        }
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

/// The real command path: the shell setup is loaded once and reused.
@MainActor
@Suite(.serialized) struct ShellSetupUITests {
    let fx = Fixture()

    func window() -> MainWindowController {
        makeWindow([fx.url, fx.url], env: testEnvironment(trash: fx.url.appendingPathComponent(".T")))
    }

    func waitFor(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    func runAndWait(_ wc: MainWindowController, _ command: String) -> Bool {
        wc.commandBar.field.stringValue = command
        wc.commandBar.submit(inTerminal: false)
        return waitFor { !wc.shell.isRunning }
    }

    @Test func firstCommandLoadsTheSetupLaterOnesReuseIt() {
        let wc = window()
        let console = wc.workspace.console
        #expect(runAndWait(wc, "ll; echo $DREVO_TEST_SETUP"))
        #expect(console.transcript.contains("Loading your shell setup"))
        #expect(console.transcript.contains("SNAPSHOT-ALIAS\nloaded\n"), "aliases and exported variables from the config")
        let loads = console.transcript.components(separatedBy: "Loading your shell setup").count - 1
        #expect(runAndWait(wc, "ll"))
        #expect(console.transcript.components(separatedBy: "Loading your shell setup").count - 1 == loads, "second command reuses the setup")
        #expect(console.transcript.components(separatedBy: "SNAPSHOT-ALIAS").count - 1 == 2)
    }

    /// A failed expectation on a window prints everything reachable from it, so the test
    /// shell setup must not hold this process's environment (it may contain API keys).
    /// The checks compare counts and names only; no value can end up in the log.
    @Test func theTestShellSetupDoesNotCarryTheProcessEnvironment() {
        let marker = "DREVO_TEST_NOT_FOR_THE_LOG"
        setenv(marker, "1", 1)
        defer { unsetenv(marker) }
        let wc = window()
        let setup = wc.env.shellSetup
        let given = Set((setup.captureEnvironment ?? ProcessInfo.processInfo.environment).keys)
        let allowed: Set<String> = ["PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "LC_CTYPE", "ZDOTDIR"]
        #expect(given.subtracting(allowed).isEmpty, "only what a scratch zsh needs")
        #expect(given.contains("ZDOTDIR") && given.contains("PATH"))

        #expect(runAndWait(wc, "ll"))
        let captured = Set((setup.snapshot?.environment ?? [:]).keys)
        #expect(!captured.isEmpty, "the setup was loaded")
        let leaked = captured.contains(marker)
        #expect(!leaked, "the captured setup has nothing of the process environment either")
    }

    @Test func focusingTheCommandLineStartsLoading() {
        let wc = window()
        #expect(wc.env.shellSetup.snapshot == nil)
        wc.commandBar.focus()
        #expect(waitFor { wc.env.shellSetup.snapshot != nil })
        #expect(runAndWait(wc, "ll"))
        #expect(!wc.workspace.console.transcript.contains("Loading your shell setup"), "already loaded while typing")
    }

    @Test func turningTheConfigOffUsesAPlainLoginShell() throws {
        let wc = window()
        // zsh reads one .zprofile — $ZDOTDIR's if that is set, else the user's — and only as
        // a login shell. Seeing the scratch one proves both: a login shell, and not one
        // that ran the user's startup files.
        let zdotdir = try #require(wc.env.shellSetup.captureEnvironment?["ZDOTDIR"])
        try "export DREVO_TEST_PROFILE=scratch-profile\n"
            .write(toFile: zdotdir + "/.zprofile", atomically: true, encoding: .utf8)
        wc.env.preferences.interactiveShell = false
        #expect(runAndWait(wc, "ll 2>&1; echo profile=$DREVO_TEST_PROFILE; echo done"))
        let transcript = wc.workspace.console.transcript
        #expect(transcript.contains("done"))
        #expect(transcript.contains("profile=scratch-profile\n"), "a login shell reading the scratch config")
        #expect(!transcript.contains("SNAPSHOT-ALIAS"), "not interactive: .zshrc is not read")
        #expect(wc.env.shellSetup.snapshot == nil, "nothing loaded")
    }
}
