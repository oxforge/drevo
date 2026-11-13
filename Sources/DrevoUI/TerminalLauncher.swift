import AppKit
import DrevoCore

/// Opens the user's terminal app at a folder.
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
}
