import Foundation
import Testing
@testable import DrevoCore

/// Uses a scratch shell config (ZDOTDIR / HOME) so tests never read the user's dotfiles.
@Suite struct ShellSnapshotTests {
    let tmp = TempDir()

    /// The few variables a scratch shell needs, not a copy of this process's
    /// environment: a failed expectation prints the snapshot, environment included, into
    /// the test log, and the full one may hold API keys.
    static var baseEnvironment: [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for key in ["PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "LC_CTYPE"] {
            env[key] = inherited[key]
        }
        return env
    }

    func run(_ snapshot: ShellSnapshot, _ command: String) throws -> (out: String, status: Int32?, seconds: Double) {
        let defs = tmp.url.appendingPathComponent("defs.sh")
        try snapshot.writeDefinitions(to: defs)
        let c = snapshot.command(command, in: tmp.url, definitionsFile: defs)
        let lock = NSLock()
        var out = ""
        var status: Int32?
        c.onOutput = { t, _ in lock.lock(); out += t; lock.unlock() }
        c.onExit = { s, _ in status = s }
        let start = Date()
        try c.start()
        #expect(c.waitUntilExit(timeout: 10))
        return (out, status, Date().timeIntervalSince(start))
    }

    func zshSnapshot() throws -> ShellSnapshot {
        let dot = tmp.dir("zdot")
        try """
        echo "noise printed by .zshrc"
        echo read >> "$ZDOTDIR/reads.log"
        alias ll='echo ALIAS-OK'
        greet() { echo "hi $1"; }
        export DREVO_TEST_VAR=from-zshrc
        export PATH="/opt/drevo-test/bin:$PATH"
        """.write(to: dot.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        var env = Self.baseEnvironment
        env["ZDOTDIR"] = dot.path
        return try ShellSnapshot.capture(shell: "/bin/zsh", environment: env)
    }

    @Test func zshAliasesFunctionsAndEnvironmentCarryOver() throws {
        let snap = try zshSnapshot()
        #expect(snap.dialect == .zsh)
        #expect(snap.environment["DREVO_TEST_VAR"] == "from-zshrc")
        #expect(snap.environment["PATH"]?.hasPrefix("/opt/drevo-test/bin:") == true)
        #expect(snap.environment["SHLVL"] == nil)
        let r = try run(snap, "ll\ngreet you\necho $DREVO_TEST_VAR\npwd")
        #expect(r.out.contains("ALIAS-OK\nhi you\nfrom-zshrc\n"))
        #expect(r.out.hasSuffix(tmp.url.lastPathComponent + "\n"), "runs in the requested folder")
        #expect(!r.out.contains("noise"), "rc output stays out of commands")
        #expect(r.status == 0)
        _ = try run(snap, "true")
        let reads = try String(contentsOf: tmp.url.appendingPathComponent("zdot/reads.log"), encoding: .utf8)
        #expect(reads == "read\n", ".zshrc is read once, when the setup is captured, not by each command")
    }

    @Test func exitStatusAndStderrPassThrough() throws {
        let snap = try zshSnapshot()
        let r = try run(snap, "echo before; exit 4")
        #expect(r.out == "before\n")
        #expect(r.status == 4)
    }

    @Test func bashToo() throws {
        let home = tmp.dir("home")
        try """
        alias ll='echo BASH-ALIAS'
        bgreet() { echo "bash hi $1"; }
        export DREVO_TEST_VAR=from-bash
        """.write(to: home.appendingPathComponent(".bash_profile"), atomically: true, encoding: .utf8)
        var env = Self.baseEnvironment
        env["HOME"] = home.path
        let snap = try ShellSnapshot.capture(shell: "/bin/bash", environment: env)
        let r = try run(snap, "ll; bgreet x; echo $DREVO_TEST_VAR")
        #expect(r.out == "BASH-ALIAS\nbash hi x\nfrom-bash\n")
    }

    @Test func goesStaleWhenAStartupFileChangesOrWithAge() throws {
        let snap = try zshSnapshot()
        #expect(snap.isFresh())
        #expect(!snap.isFresh(now: Date().addingTimeInterval(7200)))
        let rc = tmp.url.appendingPathComponent("zdot/.zshrc")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: rc.path)
        #expect(!snap.isFresh())
    }

    @Test func parseIgnoresNoiseBeforeTheMarker() throws {
        let out = "Welcome!\n" + ShellSnapshot.marker + "A=1\u{0}PATH=/x\u{0}SHLVL=2\u{0}" + ShellSnapshot.separator + "alias ll='ls -l'\n"
        let s = try #require(ShellSnapshot.parse(out, shell: "/bin/zsh", dialect: .zsh, stamps: [:]))
        #expect(s.environment == ["A": "1", "PATH": "/x"])
        #expect(s.definitions == "alias ll='ls -l'\n")
        #expect(ShellSnapshot.parse("no markers", shell: "/bin/zsh", dialect: .zsh, stamps: [:]) == nil)
    }

    @Test func otherShellsAreNotSnapshotted() {
        #expect(ShellSnapshot.dialect(of: "/opt/homebrew/bin/fish") == nil)
        #expect(throws: ShellSnapshot.CaptureError.self) { try ShellSnapshot.capture(shell: "/opt/homebrew/bin/fish") }
    }
}
