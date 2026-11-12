import Darwin
import Foundation

/// The user's login shell and how to invoke it.
public enum UserShell {
    /// The shell from the account record (what Terminal uses). GUI apps often have no
    /// $SHELL, so the account record comes first.
    public static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let s = String(cString: shell)
            if !s.isEmpty, FileManager.default.isExecutableFile(atPath: s) { return s }
        }
        if let s = ProcessInfo.processInfo.environment["SHELL"], FileManager.default.isExecutableFile(atPath: s) { return s }
        return "/bin/zsh"
    }

    /// Flags so PATH, aliases and functions match the user's terminal: login (-l) and,
    /// optionally, interactive (-i, which reads ~/.zshrc or ~/.bashrc).
    public static func flags(interactive: Bool) -> [String] {
        interactive ? ["-l", "-i"] : ["-l"]
    }

    /// Single-quotes `s` for POSIX shells: it's → 'it'\''s'.
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Strips terminal escape sequences from command output for plain display.
public enum ANSI {
    private static let patterns = [
        #"\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)"#, // OSC … BEL/ST
        #"\x1B\[[0-?]*[ -/]*[@-~]"#,               // CSI
        #"\x1B[@-Z\\-_]"#,                          // other 2-byte escapes
    ]

    public static func strip(_ s: String) -> String {
        guard s.contains("\u{1B}") || s.contains("\r") else { return s }
        var out = s
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        // Lone carriage returns (progress bars) would garble a text view; keep line breaks only.
        return out.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "")
    }
}

/// Runs one command line through a shell in a folder, in its own process group,
/// streaming stdout/stderr. Callbacks arrive on a background queue.
public final class ShellCommand: @unchecked Sendable {
    public let command: String
    public let directory: URL
    public let shell: String
    public let flags: [String]
    public var extraEnvironment: [String: String] = [:]
    public var onOutput: ((String, _ isError: Bool) -> Void)?
    /// Exit status, or nil if a signal ended it (with the signal number).
    public var onExit: ((_ status: Int32?, _ signal: Int32?) -> Void)?

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var finished = false
    private let group = DispatchGroup()
    private let exited = DispatchSemaphore(value: 0)
    private var sources: [DispatchSourceProtocol] = []

    public init(command: String, directory: URL, shell: String = UserShell.loginShell(), flags: [String] = UserShell.flags(interactive: true)) {
        self.command = command
        self.directory = directory
        self.shell = shell
        self.flags = flags
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return pid != 0 && !finished
    }

    public var processID: pid_t {
        lock.lock(); defer { lock.unlock() }
        return pid
    }

    public enum StartError: Error, LocalizedError {
        case spawn(Int32)
        public var errorDescription: String? {
            if case .spawn(let code) = self { return "Couldn’t start the shell: \(String(cString: strerror(code)))" }
            return nil
        }
    }

    public func start() throws {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { throw StartError.spawn(errno) }
        guard pipe(&errPipe) == 0 else {
            let code = errno
            close(outPipe[0]); close(outPipe[1])
            throw StartError.spawn(code)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attr, 0)
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attr, &defaults)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)

        let args = [shell] + flags + ["-c", command]
        var env = ProcessInfo.processInfo.environment
        env["PWD"] = directory.path
        env["TERM"] = "dumb"
        env["FMAN"] = "1"
        env["SHELL"] = shell
        for (k, v) in extraEnvironment { env[k] = v }
        let argv = args.map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var child: pid_t = 0
        let rc = posix_spawn(&child, shell, &actions, &attr, argv, envp)
        close(outPipe[1])
        close(errPipe[1])
        guard rc == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw StartError.spawn(rc)
        }
        lock.lock(); pid = child; lock.unlock()

        read(outPipe[0], isError: false)
        read(errPipe[0], isError: true)
        group.enter()
        let exitSource = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .global())
        let reaped = Reaped()
        // Reap exactly once, whether the exit event or the immediate check sees it first.
        let reap: (Int32) -> Void = { [weak self] options in
            var st: Int32 = 0
            guard waitpid(child, &st, options) == child else { return }
            reaped.status = st
            exitSource.cancel()
            self?.group.leave()
        }
        exitSource.setEventHandler { reap(0) }
        sources.append(exitSource)
        exitSource.resume()
        reap(WNOHANG)

        group.notify(queue: .global()) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.finished = true; self.lock.unlock()
            let status = reaped.status
            let exited = (status & 0x7f) == 0
            let code = (status >> 8) & 0xff
            let signal = status & 0x7f
            self.onExit?(exited ? code : nil, exited ? nil : signal)
            self.exited.signal()
        }
    }

    private func read(_ fd: Int32, isError: Bool) {
        group.enter()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        var decoder = UTF8Stream()
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 16384)
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n > 0 {
                let text = decoder.append(Array(buffer[0..<n]))
                if !text.isEmpty { self?.onOutput?(text, isError) }
            } else {
                source.cancel()
            }
        }
        source.setCancelHandler { [weak self] in
            let rest = decoder.flush()
            if !rest.isEmpty { self?.onOutput?(rest, isError) }
            close(fd)
            self?.group.leave()
        }
        sources.append(source)
        source.resume()
    }

    /// Ctrl-C for the whole process group; a hard kill follows if it's still running.
    public func interrupt(killAfter seconds: Double = 2) {
        let p = processID
        guard p > 0, isRunning else { return }
        kill(-p, SIGINT)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.isRunning else { return }
            kill(-p, SIGKILL)
        }
    }

    /// Blocks until the command ends (tests and scripts).
    public func waitUntilExit(timeout: Double = 30) -> Bool {
        guard exited.wait(timeout: .now() + timeout) == .success else { return false }
        exited.signal() // let other waiters through too
        return true
    }
}

/// Exit status shared between the reaping paths (waitpid succeeds only once).
private final class Reaped: @unchecked Sendable {
    var status: Int32 = 0
}

/// Decodes UTF-8 across chunk boundaries without splitting characters.
struct UTF8Stream {
    private var pending: [UInt8] = []

    mutating func append(_ bytes: [UInt8]) -> String {
        pending += bytes
        // Keep an incomplete trailing sequence for the next chunk.
        var cut = pending.count
        var i = pending.count - 1
        var back = 0
        while i >= 0, back < 4 {
            let b = pending[i]
            if b & 0xC0 == 0x80 { i -= 1; back += 1; continue }
            let need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
            if need > back + 1 { cut = i }
            break
        }
        let ready = Array(pending[0..<cut])
        pending = Array(pending[cut...])
        return String(decoding: ready, as: UTF8.self)
    }

    mutating func flush() -> String {
        defer { pending = [] }
        return String(decoding: pending, as: UTF8.self)
    }
}
