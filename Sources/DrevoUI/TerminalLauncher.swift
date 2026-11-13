import AppKit
import DrevoCore

/// Opens the user's terminal app at a folder, optionally running a command there.
@MainActor
enum TerminalLauncher {
    static let defaultTerminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")

    /// Known terminals, in the order offered in Settings (only installed ones are shown).
    static let knownTerminals: [String] = [
        "/System/Applications/Utilities/Terminal.app", "/Applications/iTerm.app", "/Applications/Ghostty.app",
        "/Applications/Warp.app", "/Applications/WezTerm.app", "/Applications/kitty.app", "/Applications/Alacritty.app",
    ]

    static func installedTerminals() -> [URL] {
        knownTerminals.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static func terminalApp(_ preferences: Preferences) -> URL {
        if let path = preferences.terminalAppPath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return defaultTerminal
    }

    /// New terminal window at `folder` (Terminal, iTerm2, Ghostty, Warp accept a folder).
    static func open(_ folder: URL, env: AppEnvironment) {
        env.opener.open([folder], withApplicationAt: terminalApp(env.preferences))
    }

    /// Runs `command` in a new terminal window at `folder` via a temporary .command script,
    /// leaving an interactive shell open afterwards.
    static func run(_ command: String, in folder: URL, env: AppEnvironment) throws {
        let script = try writeScript(command: command, folder: folder, shell: UserShell.loginShell(), into: env.terminalScriptsFolder)
        env.opener.open([script], withApplicationAt: terminalApp(env.preferences))
    }

    /// Where scripts go unless the environment says otherwise (`AppEnvironment.terminalScriptsFolder`).
    nonisolated static var scriptsFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("tech.oxforge.drevo/commands", isDirectory: true)
    }

    static func scriptText(command: String, folder: URL, shell: String) -> String {
        let q = UserShell.quote
        let inner = "\(command)\nexec \(q(shell)) -l -i"
        return """
        #!/bin/sh
        # Written by Drevo to run a command in your terminal; safe to delete.
        rm -f "$0"
        cd \(q(folder.path)) || exit 1
        exec \(q(shell)) -l -i -c \(q(inner))

        """
    }

    static func writeScript(command: String, folder: URL, shell: String, into dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cleanOldScripts(in: dir)
        let url = dir.appendingPathComponent("run-\(UUID().uuidString.prefix(8)).command")
        try scriptText(command: command, folder: folder, shell: shell).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// Scripts delete themselves when they run; this catches ones that never ran.
    private static func cleanOldScripts(in dir: URL) {
        let old = Date().addingTimeInterval(-24 * 3600)
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for u in items where ((try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < old {
            try? FileManager.default.removeItem(at: u)
        }
    }
}
