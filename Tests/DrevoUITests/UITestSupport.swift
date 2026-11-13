import AppKit
import Foundation
@testable import DrevoCore
@testable import DrevoUI

/// A scratch folder deleted when the value goes away.
final class Fixture {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("drevo-ui-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ path: String, _ contents: String = "x") -> URL {
        let u = url.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! contents.data(using: .utf8)!.write(to: u)
        return u
    }

    @discardableResult
    func dir(_ path: String) -> URL {
        let u = url.appendingPathComponent(path, isDirectory: true)
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

/// Records opens instead of launching apps.
@MainActor
final class RecordingOpener: FileOpening {
    var opened: [[URL]] = []
    func open(_ urls: [URL]) { opened.append(urls) }
    func open(_ urls: [URL], withApplicationAt app: URL) { opened.append(urls) }
}

/// Answers prompts from a script instead of showing sheets.
@MainActor
final class ScriptedPrompts: UserPrompts {
    var deleteAnswer = true
    var destination: URL??  // nil = accept proposed; .some(nil) = cancel
    nonisolated(unsafe) var conflictAnswer = ConflictDecision(.keepBoth)
    nonisolated(unsafe) var conflicts: [Conflict] = []
    var errors: [String] = []
    var askedDestination: URL?

    func confirmDelete(_ urls: [URL], in window: NSWindow?, then: @escaping (Bool) -> Void) { then(deleteAnswer) }
    var typedDestination: String?
    var askedBase: URL?
    func askDestination(kind: TransferKind, count: Int, proposed: URL, base: URL, in window: NSWindow?, then: @escaping (URL?) -> Void) {
        askedDestination = proposed
        askedBase = base
        if let typed = typedDestination {
            return then(URL(fileURLWithPath: PathCompletion.expand(typed, relativeTo: base)))
        }
        then(destination ?? proposed)
    }
    nonisolated func resolveConflict(_ conflict: Conflict, in window: NSWindow?) -> ConflictDecision {
        conflicts.append(conflict)
        return conflictAnswer
    }
    func showError(_ message: String, detail: String?, in window: NSWindow?) { errors.append(message + " " + (detail ?? "")) }
    var confirmAnswer = true
    var confirmations: [String] = []
    func confirm(_ message: String, detail: String?, button: String, in window: NSWindow?, then: @escaping (Bool) -> Void) {
        confirmations.append(message)
        then(confirmAnswer)
    }
}

/// The environment a scratch zsh starts from: the few variables it needs, not a copy of
/// this process's environment. The setup (and the snapshot captured from it) hangs off
/// every window, and a failed expectation on a window or pane prints all of it into the
/// test log — where the full environment could put API keys and tokens.
func scratchShellEnvironment(zdotdir: URL) -> [String: String] {
    let inherited = ProcessInfo.processInfo.environment
    var env: [String: String] = [:]
    for key in ["PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "LC_CTYPE"] {
        env[key] = inherited[key]
    }
    env["ZDOTDIR"] = zdotdir.path
    return env
}

/// An environment that never touches the real Trash, clipboard or apps.
@MainActor
func testEnvironment(trash: URL, prompts: ScriptedPrompts? = nil, opener: RecordingOpener? = nil) -> AppEnvironment {
    let prompts = prompts ?? ScriptedPrompts()
    let opener = opener ?? RecordingOpener()
    let ops = OperationsCenter(ops: FileOperations(trash: FolderTrash(folder: trash)), prompts: prompts)
    ops.runTransfersSynchronously = true
    // A shell setup that reads a scratch config and writes a scratch cache, never the user's.
    let scratch = trash.deletingLastPathComponent().appendingPathComponent("zdot-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    try? "alias ll='echo SNAPSHOT-ALIAS'\nexport DREVO_TEST_SETUP=loaded\n".write(to: scratch.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
    let setup = ShellSetup(shell: "/bin/zsh", definitionsFile: scratch.appendingPathComponent("defs.sh"))
    setup.captureEnvironment = scratchShellEnvironment(zdotdir: scratch)
    let env = AppEnvironment.ephemeral(opener: opener, operations: ops, shellSetup: setup)
    env.spotlight = nil
    env.runSearchesSynchronously = true
    env.pasteboard = NSPasteboard(name: NSPasteboard.Name("drevo.tests.\(UUID().uuidString)"))
    return env
}

@MainActor
func makeWindow(_ dirs: [URL], modes: [ViewMode] = [.list, .list], env: AppEnvironment? = nil) -> MainWindowController {
    let env = env ?? testEnvironment(trash: FileManager.default.temporaryDirectory.appendingPathComponent("drevo-trash-\(UUID().uuidString)"))
    let wc = MainWindowController(env: env, directories: dirs, viewModes: modes, autosave: false)
    wc.window!.layoutIfNeeded()
    wc.paneGroup.activePane.focus()
    return wc
}

/// A synthetic key press. keyCode decides named keys; characters decide the rest.
@MainActor
func key(_ keyCode: UInt16, _ chars: String = "", _ flags: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                     windowNumber: window.windowNumber, context: nil, characters: chars,
                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
}

enum KeyCode {
    static let tab: UInt16 = 48, returnKey: UInt16 = 36, left: UInt16 = 123, right: UInt16 = 124
    static let down: UInt16 = 125, up: UInt16 = 126, one: UInt16 = 18, period: UInt16 = 47, f5: UInt16 = 96
}

/// Sends a key to whatever has focus in the window, like a real key press would.
@MainActor
func press(_ event: NSEvent, in window: NSWindow) {
    if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return }
    window.firstResponder?.keyDown(with: event)
}
