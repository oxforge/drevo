import AppKit
import FmanCore

/// Runs command-line commands for one window and feeds the console.
@MainActor
final class ShellSession {
    private(set) var running: ShellCommand?
    private let console: ConsoleViewController
    private let preferences: Preferences
    private let setup: ShellSetup
    var onFinish: (() -> Void)?
    /// Tests use a shell without the user's rc files.
    var shellOverride: (shell: String, flags: [String])?
    /// A command is waiting for the shell setup to load.
    private var waitingForSetup = false
    /// Output of the running command that the console hasn't shown yet.
    private var backlog: OutputBacklog?
    private var flushTimer: Timer?
    /// The console catches up this often (~30 Hz) however fast the command prints, so the
    /// main thread has at least this long for everything else between two updates.
    static let flushInterval: TimeInterval = 1.0 / 30

    init(console: ConsoleViewController, preferences: Preferences, setup: ShellSetup) {
        self.console = console
        self.preferences = preferences
        self.setup = setup
    }

    var isRunning: Bool { (running?.isRunning ?? false) || waitingForSetup }

    /// Called when the command line gets focus: load the shell setup while the user types.
    func prepare() {
        if shellOverride == nil, preferences.interactiveShell { setup.prepare() }
    }

    /// Runs `command` in `directory`. With "Load interactive config" on (zsh/bash), it uses
    /// the shell setup loaded once instead of re-reading ~/.zshrc for every command.
    @discardableResult
    func run(_ command: String, in directory: URL) -> Bool {
        guard !isRunning else { return false }
        let started = Date()
        console.begin(command: command, directory: directory)
        if let o = shellOverride {
            return start(fullShell(command, in: directory, shell: o.shell, flags: o.flags), started: started)
        }
        guard preferences.interactiveShell else {
            return start(fullShell(command, in: directory, shell: setup.shell, flags: UserShell.flags(interactive: false)), started: started)
        }
        guard setup.isSupported else {
            return start(fullShell(command, in: directory, shell: setup.shell, flags: UserShell.flags(interactive: true)), started: started)
        }
        if let snapshot = setup.freshSnapshot {
            return start(snapshot.command(command, in: directory, definitionsFile: setup.definitionsFile), started: started)
        }
        console.note("Loading your shell setup — once; later commands reuse it until your shell config changes.")
        waitingForSetup = true
        setup.withSnapshot { [weak self] snapshot in
            guard let self, self.waitingForSetup else { return } // stopped meanwhile
            self.waitingForSetup = false
            if let snapshot {
                self.start(snapshot.command(command, in: directory, definitionsFile: self.setup.definitionsFile), started: started)
            } else {
                self.console.note("Couldn’t load your shell setup (\(self.setup.lastError ?? "unknown error")); running with a full shell instead.")
                self.start(self.fullShell(command, in: directory, shell: self.setup.shell, flags: UserShell.flags(interactive: true)), started: started)
            }
        }
        return true
    }

    /// A shell that starts in full rather than from the loaded setup. It gets the
    /// environment the setup is captured from: this process's in the app, the scratch one
    /// in tests — so no test shell reads the user's startup files.
    private func fullShell(_ command: String, in directory: URL, shell: String, flags: [String]) -> ShellCommand {
        let cmd = ShellCommand(command: command, directory: directory, shell: shell, flags: flags)
        cmd.baseEnvironment = setup.captureEnvironment
        return cmd
    }

    @discardableResult
    private func start(_ cmd: ShellCommand, started: Date) -> Bool {
        // Output collects off the main thread; only the first chunk after an update wakes it.
        let backlog = OutputBacklog(limit: ConsoleViewController.backlogLimit)
        cmd.onOutput = { [weak self] text, isError in
            guard backlog.append(text, isError: isError) else { return }
            onMainRunLoop { self?.scheduleFlush(of: backlog) }
        }
        cmd.onExit = { [weak self] status, signal in
            onMainRunLoop {
                guard let self else { return }
                self.flushTimer?.invalidate()
                self.flushTimer = nil
                self.backlog = nil
                self.console.append(backlog.take()) // the rest, before the exit line
                self.console.finish(status: status, signal: signal, duration: Date().timeIntervalSince(started))
                self.running = nil
                self.onFinish?()
            }
        }
        do {
            try cmd.start()
            running = cmd
            self.backlog = backlog
            return true
        } catch {
            console.append("\(error.localizedDescription)\n", isError: true)
            console.finish(status: 127, signal: nil, duration: 0)
            return false
        }
    }

    /// Shows the backlog one interval from now, unless that is already due.
    private func scheduleFlush(of backlog: OutputBacklog) {
        guard self.backlog === backlog, flushTimer == nil else { return }
        let timer = Timer(timeInterval: Self.flushInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.backlog === backlog else { return }
                // Cleared before taking: text that arrives after the take schedules the next one.
                self.flushTimer = nil
                self.console.append(backlog.take())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }

    /// Ctrl-C; a hard kill follows if the command is still running two seconds later.
    func stop() {
        if cancelWaitingForSetup() { return }
        running?.interrupt()
    }

    /// Ends the command before returning (quitting, where a later hard kill would never run).
    func terminate() {
        if cancelWaitingForSetup() { return }
        running?.terminate()
    }

    private func cancelWaitingForSetup() -> Bool {
        guard waitingForSetup else { return false }
        waitingForSetup = false
        console.finish(status: nil, signal: SIGINT, duration: 0)
        return true
    }
}
