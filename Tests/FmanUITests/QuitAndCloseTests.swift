import AppKit
import Testing
@testable import FmanCore
@testable import FmanUI

/// Quitting and closing a window while a command runs (review M3).
@MainActor
@Suite(.serialized) struct QuitAndCloseTests {
    let fx = Fixture()

    func waitFor(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    func delegate(_ env: AppEnvironment) -> AppDelegate {
        let d = AppDelegate(options: LaunchOptions(arguments: ["fman", "--ephemeral"]))
        d.useEnvironmentForTests(env)
        return d
    }

    /// A window with `command` running; returns once the command has printed "ready".
    func windowRunning(_ command: String, _ d: AppDelegate) -> (MainWindowController, pid_t) {
        let wc = d.openWindow(directories: [fx.url, fx.url], viewModes: [.list, .list])
        return (wc, run(command, in: wc))
    }

    /// Starts `command` in the window's command line; returns once it has printed "ready".
    func run(_ command: String, in wc: MainWindowController) -> pid_t {
        wc.shell.shellOverride = ("/bin/zsh", ["-f"]) // never run the user's rc files in tests
        wc.commandBar.field.stringValue = command
        wc.commandBar.submit(inTerminal: false)
        #expect(waitFor { wc.shell.isRunning && wc.workspace.console.transcript.contains("\nready\n") })
        return wc.shell.running?.processID ?? 0
    }

    /// Ignores Ctrl-C, as does the `sleep` it starts.
    let stubborn = "trap '' INT; echo ready; sleep 30"
    let obedient = "echo ready; sleep 30"

    func isAlive(_ pid: pid_t) -> Bool { pid > 0 && kill(pid, 0) == 0 }

    /// A test environment with one background job that stays unfinished until it is
    /// cancelled: expanding an "archive" that is a pipe nobody writes to.
    func environmentWithPendingJob() -> AppEnvironment {
        let env = testEnvironment(trash: fx.url.appendingPathComponent(".T"))
        env.operations.runTransfersSynchronously = false
        let pipe = fx.url.appendingPathComponent("held.tar")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        env.operations.extract([pipe], window: nil)
        #expect(env.operations.jobs.count == 1)
        return env
    }

    @Test func keepRunningLeavesCommandsAlone() {
        let env = environmentWithPendingJob()
        let d = delegate(env)
        let (wc, pid) = windowRunning(obedient, d)
        var askedAbout: [Int] = []
        d.confirmQuit = { jobs in askedAbout.append(jobs); return false } // "Keep Running"

        #expect(d.applicationShouldTerminate(NSApp) == .terminateCancel)
        #expect(askedAbout == [1])
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        #expect(wc.shell.isRunning, "the app stays, and so does the command")
        #expect(isAlive(pid))
        #expect(env.operations.jobs.count == 1, "…and the job")

        env.operations.cancelAll()
        #expect(waitFor { env.operations.jobs.isEmpty })
        wc.shell.stop()
        #expect(waitFor { !wc.shell.isRunning })
        wc.close()
    }

    @Test func stopAndQuitEndsCommandsBeforeReplying() {
        let env = environmentWithPendingJob()
        let d = delegate(env)
        let (wc, pid) = windowRunning(stubborn, d)
        d.confirmQuit = { _ in true } // "Stop and Quit"
        var replies: [Bool] = []
        d.replyToTerminate = { replies.append($0) }

        #expect(d.applicationShouldTerminate(NSApp) == .terminateLater)
        #expect(replies.isEmpty, "waits for the job to clean up")
        #expect(isAlive(pid), "Ctrl-C alone doesn't end this one")
        #expect(waitFor { replies == [true] })
        #expect(env.operations.jobs.isEmpty)
        #expect(waitFor(1) { !isAlive(pid) }, "a command that ignores Ctrl-C does not outlive the app")
        wc.close()
    }

    @Test func quittingWithNothingToAskAboutEndsCommands() {
        let d = delegate(testEnvironment(trash: fx.url.appendingPathComponent(".T")))
        let (wc, pid) = windowRunning(stubborn, d)
        d.confirmQuit = { _ in Issue.record("no job is running: nothing to ask"); return false }
        let start = Date()
        #expect(d.applicationShouldTerminate(NSApp) == .terminateNow)
        #expect(Date().timeIntervalSince(start) < 1.5, "a short wait, not the two seconds of Stop's fallback")
        #expect(waitFor(1) { !isAlive(pid) }, "killed before the app is gone")
        wc.close()
    }

    @Test func closingAWindowStopsItsCommand() {
        let d = delegate(testEnvironment(trash: fx.url.appendingPathComponent(".T")))
        let (wc, pid) = windowRunning(obedient, d)
        #expect(isAlive(pid))
        wc.close()
        #expect(!d.windowControllers.contains { $0 === wc })
        #expect(waitFor(3) { !isAlive(pid) })
    }

    /// The quit question fits whatever is running: the job may be an archive being expanded.
    @Test func theQuitQuestionFitsAnyJob() {
        for count in [1, 3] {
            let question = AppDelegate.quitQuestion(jobCount: count)
            #expect(!question.lowercased().contains("cop") && !question.lowercased().contains("mov"))
        }
        #expect(AppDelegate.quitQuestion(jobCount: 3).contains("3"))
    }

    /// The window looks after its own command: nobody else watches this one close.
    @Test func aWindowOpenedWithoutTheAppDelegateStopsItsCommandToo() {
        let wc = makeWindow([fx.url, fx.url], env: testEnvironment(trash: fx.url.appendingPathComponent(".T")))
        let pid = run(obedient, in: wc)
        #expect(isAlive(pid))
        wc.close()
        #expect(waitFor(3) { !isAlive(pid) })
    }
}
