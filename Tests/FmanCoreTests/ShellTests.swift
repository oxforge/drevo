import Foundation
import Testing
@testable import FmanCore

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
    let r = run("cat; echo \"[$FMAN][$TERM]\"", in: tmp.url)
    #expect(r.out == "[1][dumb]\n")
}

@Test func interruptStopsWholePipeline() {
    let tmp = TempDir()
    let start = Date()
    let r = run("sleep 30 | cat", in: tmp.url) { c in
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { c.interrupt(killAfter: 1) }
    }
    #expect(Date().timeIntervalSince(start) < 5)
    #expect(r.status != 0)
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

@Test func loginShellIsAnExecutable() {
    #expect(FileManager.default.isExecutableFile(atPath: UserShell.loginShell()))
    #expect(UserShell.flags(interactive: true) == ["-l", "-i"])
}

@Test func quoting() {
    #expect(UserShell.quote("it's here") == "'it'\\''s here'")
}

@Test func stripsEscapes() {
    #expect(ANSI.strip("\u{1B}[1;31mred\u{1B}[0m ok") == "red ok")
    #expect(ANSI.strip("\u{1B}]0;title\u{07}text") == "text")
    #expect(ANSI.strip("a\r\nb\rc") == "a\nbc")
}
