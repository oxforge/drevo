import Foundation
import Testing
@testable import DrevoCore

/// Runs with zsh -f (no rc files) so tests never depend on the user's shell config.
private func run(_ cmd: String, in dir: URL, timeout: Double = 10, configure: ((ShellCommand) -> Void)? = nil)
    -> (out: String, err: String, status: Int32?, signal: Int32?)
{
    let c = ShellCommand(command: cmd, directory: dir, shell: "/bin/zsh", flags: ["-f"])
    let lock = NSLock()
    var out = "", err = ""
    var status: Int32?, signal: Int32?
    c.onOutput = { text, isErr in lock.lock(); if isErr { err += text } else { out += text }; lock.unlock() }
    c.onExit = { s, sig in status = s; signal = sig }
    configure?(c)
    try! c.start()
    #expect(c.waitUntilExit(timeout: timeout))
    return (out, err, status, signal)
}

@Test func runsInFolderAndSeparatesStreams() {
    let tmp = TempDir()
    let r = run("pwd; echo oops >&2; exit 3", in: tmp.url)
    #expect(r.out.trimmingCharacters(in: .newlines).hasSuffix(tmp.url.lastPathComponent))
    #expect(r.err == "oops\n")
    #expect(r.status == 3)
}

@Test func stdinIsEmptyAndEnvironmentIsMarked() {
    let tmp = TempDir()
    let r = run("cat; echo \"[$DREVO][$TERM]\"", in: tmp.url)
    #expect(r.out == "[1][dumb]\n")
}

@Test func interruptStopsWholePipeline() {
    let tmp = TempDir()
    // A queue of its own, as ShellCommand uses: the global queue runs nothing while busy
    // work fills its threads (one per CPU), which held this Ctrl-C back ~5 s on a 3-core
    // CI runner while other tests ran.
    let timer = DispatchQueue(label: "interrupt-timer")
    // The hard kill comes long after the helper stops waiting, so only Ctrl-C can end
    // `sleep 30` in time.
    let r = run("sleep 30 | cat", in: tmp.url) { c in
        timer.asyncAfter(deadline: .now() + 0.3) { c.interrupt(killAfter: 30) }
    }
    #expect(r.signal == SIGINT, "the shell ended by Ctrl-C, not by the hard kill")
}

@Test func largeOutputArrivesComplete() {
    let tmp = TempDir()
    let r = run("for i in {1..20000}; do echo line-$i; done", in: tmp.url)
    #expect(r.out.split(separator: "\n").count == 20000)
    #expect(r.out.hasSuffix("line-20000\n"))
}

@Test func utf8SplitAcrossChunks() {
    var s = UTF8Stream()
    let bytes = Array("héllo→✓".utf8)
    var out = ""
    for b in bytes { out += s.append([b]) }
    out += s.flush()
    #expect(out == "héllo→✓")
}

// MARK: Background processes

@Test func outputWrittenBeforeExitSurvivesABackgroundProcess() {
    let tmp = TempDir()
    var command: ShellCommand?
    // The sleep holds the pipes open long after the shell exits: only the drain window
    // ends the command within the helper's wait.
    let r = run("sleep 30 & for i in {1..3000}; do echo line-$i; done", in: tmp.url) { command = $0 }
    #expect(r.status == 0)
    #expect(r.out.split(separator: "\n").count == 3000)
    #expect(r.out.hasSuffix("line-3000\n"))
    // The sleep is still running, in the process group the shell led.
    if let pid = command?.processID, pid > 0 { kill(-pid, SIGKILL) }
}
