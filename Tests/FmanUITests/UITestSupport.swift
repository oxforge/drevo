import AppKit
import Foundation
@testable import FmanCore
@testable import FmanUI

/// A scratch folder deleted when the value goes away.
final class Fixture {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fman-ui-\(UUID().uuidString)", isDirectory: true)
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
    func askDestination(kind: TransferKind, count: Int, proposed: URL, in window: NSWindow?, then: @escaping (URL?) -> Void) {
        askedDestination = proposed
        then(destination ?? proposed)
    }
    nonisolated func resolveConflict(_ conflict: Conflict, in window: NSWindow?) -> ConflictDecision {
        conflicts.append(conflict)
        return conflictAnswer
    }
    func showError(_ message: String, detail: String?, in window: NSWindow?) { errors.append(message + " " + (detail ?? "")) }
}

/// An environment that never touches the real Trash, clipboard or apps.
@MainActor
func testEnvironment(trash: URL, prompts: ScriptedPrompts? = nil, opener: RecordingOpener? = nil) -> AppEnvironment {
    let prompts = prompts ?? ScriptedPrompts()
    let opener = opener ?? RecordingOpener()
    let ops = OperationsCenter(ops: FileOperations(trash: FolderTrash(folder: trash)), prompts: prompts)
    ops.runTransfersSynchronously = true
    let env = AppEnvironment.ephemeral(opener: opener, operations: ops)
    env.pasteboard = NSPasteboard(name: NSPasteboard.Name("fman.tests.\(UUID().uuidString)"))
    return env
}

@MainActor
func makeWindow(_ dirs: [URL], modes: [ViewMode] = [.list, .list], env: AppEnvironment? = nil) -> MainWindowController {
    let env = env ?? testEnvironment(trash: FileManager.default.temporaryDirectory.appendingPathComponent("fman-trash-\(UUID().uuidString)"))
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
    (window.firstResponder as? NSResponder)?.keyDown(with: event)
}
