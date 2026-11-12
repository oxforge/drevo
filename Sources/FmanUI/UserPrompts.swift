import AppKit
import FmanCore

/// Questions the app asks the user. Sheets in the app; scripted answers in tests.
@MainActor
protocol UserPrompts: AnyObject {
    /// "Delete immediately?" — permanent deletion.
    func confirmDelete(_ urls: [URL], in window: NSWindow?, then: @escaping (Bool) -> Void)
    /// F5/F6 sheet: where to copy/move; nil = cancelled. Relative input resolves against `base`.
    func askDestination(kind: TransferKind, count: Int, proposed: URL, base: URL, in window: NSWindow?, then: @escaping (URL?) -> Void)
    /// Called on the transfer's worker thread; may block until answered.
    nonisolated func resolveConflict(_ conflict: Conflict, in window: NSWindow?) -> ConflictDecision
    func showError(_ message: String, detail: String?, in window: NSWindow?)
}

// MARK: - Sheets

@MainActor
final class SheetPrompts: UserPrompts {
    func confirmDelete(_ urls: [URL], in window: NSWindow?, then: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = urls.count == 1
            ? "Are you sure you want to delete “\(urls[0].lastPathComponent)” immediately?"
            : "Are you sure you want to delete these \(urls.count) items immediately?"
        alert.informativeText = "You can’t undo this action."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        present(alert, in: window) { then($0 == .alertFirstButtonReturn) }
    }

    func askDestination(kind: TransferKind, count: Int, proposed: URL, base: URL, in window: NSWindow?, then: @escaping (URL?) -> Void) {
        let alert = NSAlert()
        let verb = kind == .copy ? "Copy" : "Move"
        alert.messageText = "\(verb) \(count == 1 ? "1 item" : "\(count) items") to:"
        alert.informativeText = "Return confirms, Esc cancels. You can edit the folder."
        let field = NSTextField(string: (proposed.path as NSString).abbreviatingWithTildeInPath)
        field.frame = NSRect(x: 0, y: 0, width: 420, height: 24)
        field.lineBreakMode = .byTruncatingHead
        alert.accessoryView = field
        alert.addButton(withTitle: verb)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        present(alert, in: window) { response in
            guard response == .alertFirstButtonReturn else { return then(nil) }
            // Like the path bar: "~" expands, relative paths start at the source pane's folder.
            then(URL(fileURLWithPath: PathCompletion.expand(field.stringValue, relativeTo: base)))
        }
    }

    nonisolated func resolveConflict(_ conflict: Conflict, in window: NSWindow?) -> ConflictDecision {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var decision = ConflictDecision(.stop)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let alert = NSAlert()
                alert.alertStyle = .warning
                let name = conflict.existing.lastPathComponent
                let folder = conflict.existing.deletingLastPathComponent().lastPathComponent
                alert.messageText = "An item named “\(name)” already exists in “\(folder)”."
                alert.informativeText = conflict.existingIsFolder
                    ? "Replacing it moves the existing folder and everything in it to the Trash."
                    : "Replacing it moves the existing item to the Trash."
                for title in ["Replace", "Keep Both", "Skip", "Stop"] { alert.addButton(withTitle: title) }
                if conflict.remaining > 0 {
                    alert.showsSuppressionButton = true
                    alert.suppressionButton?.title = "Apply to all (\(conflict.remaining) more)"
                }
                self.present(alert, in: window) { response in
                    let all = alert.suppressionButton?.state == .on
                    let action: ConflictAction
                    switch response {
                    case .alertFirstButtonReturn: action = .replace
                    case .alertSecondButtonReturn: action = .keepBoth
                    case .alertThirdButtonReturn: action = .skip
                    default: action = .stop
                    }
                    decision = ConflictDecision(action, applyToAll: all)
                    semaphore.signal()
                }
            }
        }
        semaphore.wait()
        return decision
    }

    func showError(_ message: String, detail: String?, in window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail ?? ""
        present(alert, in: window) { _ in }
    }

    private func present(_ alert: NSAlert, in window: NSWindow?, then: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = window ?? NSApp.keyWindow, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: then)
        } else {
            then(alert.runModal())
        }
    }
}
