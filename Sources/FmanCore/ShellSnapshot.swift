import Foundation

/// The user's shell setup, captured once from a full login + interactive shell and reused
/// so each command starts in milliseconds instead of re-running ~/.zshrc every time.
///
/// Holds the environment (PATH and everything exported) plus alias and function
/// definitions. Commands then run in a bare shell (`zsh -f`, `bash --norc`) that loads the
/// definitions and `eval`s the command, so aliases still expand. What's lost: shell options
/// (`setopt`) and unexported variables set in rc files.
public struct ShellSnapshot: Equatable, Sendable {
    public enum Dialect: String, Sendable {
        case zsh, bash
    }

    public let shell: String
    public let dialect: Dialect
    public let environment: [String: String]
    /// Aliases and functions in the shell's own syntax.
    public let definitions: String
    public let capturedAt: Date
    /// Modification dates of the startup files at capture time (nil = file missing).
    public let startupFileStamps: [String: Date?]

    /// Shells this works for; anything else keeps starting a full shell per command.
    public static func dialect(of shell: String) -> Dialect? {
        switch (shell as NSString).lastPathComponent {
        case "zsh": return .zsh
        case "bash": return .bash
        default: return nil
        }
    }

    // MARK: Capture

    static let marker = "\u{0}__FMAN_SNAPSHOT__\u{0}"
    static let separator = "\u{0}__FMAN_DEFS__\u{0}"

    /// Prints the marker, `env -0`, a separator, then aliases and (non-completion) functions.
    static func dumpScript(_ dialect: Dialect) -> String {
        switch dialect {
        case .zsh:
            return #"""
            printf '\0__FMAN_SNAPSHOT__\0'; env -0; printf '\0__FMAN_DEFS__\0'
            alias -L
            for f in ${(ok)functions}; do
              [[ $f == _* || $functions[$f] == *"builtin autoload -X"* ]] && continue
              typeset -f -- "$f"
            done
            """#
        case .bash:
            return #"""
            printf '\0__FMAN_SNAPSHOT__\0'; env -0; printf '\0__FMAN_DEFS__\0'
            alias -p
            for f in $(compgen -A function); do
              case "$f" in _*) ;; *) declare -f "$f" ;; esac
            done
            """#
        }
    }

    public enum CaptureError: LocalizedError, Equatable {
        case unsupportedShell(String)
        case timedOut
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedShell(let s): return "\(s) isn’t supported for a reusable shell setup."
            case .timedOut: return "Your shell configuration took too long to load."
            case .failed(let why): return "Couldn’t read your shell configuration: \(why)"
            }
        }
    }

    /// Runs `shell -l -i` once and records its setup. `environment` overrides the process
    /// environment (tests point ZDOTDIR/HOME at a scratch config). Blocks; call off the main thread.
    public static func capture(shell: String, environment: [String: String]? = nil, timeout: TimeInterval = 20) throws -> ShellSnapshot {
        guard let dialect = dialect(of: shell) else { throw CaptureError.unsupportedShell(shell) }
        var env = environment ?? ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        let stamps = startupFileStamps(dialect, environment: env)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-i", "-c", dumpScript(dialect)]
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: env["HOME"] ?? NSHomeDirectory())
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        if p.terminationReason == .uncaughtSignal { throw CaptureError.timedOut }
        guard let snapshot = parse(String(decoding: data, as: UTF8.self), shell: shell, dialect: dialect, stamps: stamps) else {
            throw CaptureError.failed("exit status \(p.terminationStatus), no output")
        }
        return snapshot
    }

    /// Reads the dump; anything rc files printed before the marker is ignored.
    static func parse(_ output: String, shell: String, dialect: Dialect, stamps: [String: Date?], now: Date = Date()) -> ShellSnapshot? {
        guard let start = output.range(of: marker, options: .backwards),
              let sep = output.range(of: separator, range: start.upperBound..<output.endIndex) else { return nil }
        var env: [String: String] = [:]
        for entry in output[start.upperBound..<sep.lowerBound].split(separator: "\u{0}", omittingEmptySubsequences: true) {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        // Per-process values that mustn't leak into commands.
        for key in ["SHLVL", "_", "OLDPWD", "PWD", "TERM"] { env[key] = nil }
        let definitions = String(output[sep.upperBound...])
        return ShellSnapshot(shell: shell, dialect: dialect, environment: env, definitions: definitions,
                             capturedAt: now, startupFileStamps: stamps)
    }

    // MARK: Freshness

    /// The files a login + interactive shell reads.
    static func startupFiles(_ dialect: Dialect, environment env: [String: String]) -> [String] {
        let home = env["HOME"] ?? NSHomeDirectory()
        switch dialect {
        case .zsh:
            let dot = env["ZDOTDIR"] ?? home
            return ["/etc/zshenv", "/etc/zprofile", "/etc/zshrc", "/etc/zlogin"]
                + [".zshenv", ".zprofile", ".zshrc", ".zlogin"].map { (dot as NSString).appendingPathComponent($0) }
        case .bash:
            return ["/etc/profile", "/etc/bashrc"]
                + [".bash_profile", ".bash_login", ".profile", ".bashrc"].map { (home as NSString).appendingPathComponent($0) }
        }
    }

    static func startupFileStamps(_ dialect: Dialect, environment: [String: String]) -> [String: Date?] {
        var stamps: [String: Date?] = [:]
        for path in startupFiles(dialect, environment: environment) {
            stamps[path] = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
        return stamps
    }

    /// Still valid: no startup file changed, and not older than `maxAge` (tools such as
    /// installers can change what rc files compute without editing them).
    public func isFresh(now: Date = Date(), maxAge: TimeInterval = 3600) -> Bool {
        guard now.timeIntervalSince(capturedAt) < maxAge else { return false }
        var env = environment
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        return Self.startupFileStamps(dialect, environment: env) == startupFileStamps
    }

    // MARK: Running

    /// Writes the definitions where the bare shell can source them.
    public func writeDefinitions(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try definitions.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A command that runs with this setup: bare shell + definitions + `eval`, so aliases
    /// expand (they're defined before the command is parsed).
    public func command(_ command: String, in directory: URL, definitionsFile: URL) -> ShellCommand {
        let script: String
        let flags: [String]
        switch dialect {
        case .zsh:
            flags = ["-f"]
            script = #"source "$FMAN_DEFINITIONS" 2>/dev/null; eval "$FMAN_COMMAND""#
        case .bash:
            flags = ["--noprofile", "--norc"]
            script = #"shopt -s expand_aliases; source "$FMAN_DEFINITIONS" 2>/dev/null; eval "$FMAN_COMMAND""#
        }
        let c = ShellCommand(command: script, directory: directory, shell: shell, flags: flags)
        c.baseEnvironment = environment
        c.extraEnvironment = ["FMAN_COMMAND": command, "FMAN_DEFINITIONS": definitionsFile.path]
        return c
    }
}
