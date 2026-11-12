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

/// A running or finished copy/move, observed by the operations bar.
@MainActor
final class TransferJob: Identifiable {
    let id = UUID()
    let transfer: Transfer
    let title: String
    fileprivate(set) var progress = TransferProgress()
    fileprivate(set) var isFinished = false
    let started = Date()

    init(transfer: Transfer) {
        self.transfer = transfer
        self.title = transfer.title
    }
}

/// Runs file operations for every window: undo/redo, background transfers, refresh.
@MainActor
final class OperationsCenter {
    static let filesDidChange = Notification.Name("fman.filesDidChange")
    static let jobsDidChange = Notification.Name("fman.jobsDidChange")

    let ops: FileOperations
    let undoManager = UndoManager()
    var prompts: UserPrompts
    /// Tests run transfers inline so results are visible right after the call.
    var runTransfersSynchronously = false
    private(set) var jobs: [TransferJob] = []

    init(ops: FileOperations = FileOperations(), prompts: UserPrompts) {
        self.ops = ops
        self.prompts = prompts
        undoManager.levelsOfUndo = 50
    }

    // MARK: Simple operations

    /// Runs `body`, registers its undo under `name`, refreshes panes, reports errors.
    @discardableResult
    func perform<T>(_ name: String, in window: NSWindow?, _ body: () throws -> (T, UndoRecord?)) -> T? {
        do {
            let (value, record) = try body()
            if let record, !record.isEmpty { registerUndo(record, name: name) }
            postChange()
            return value
        } catch let partial as PartialFailure {
            registerUndo(partial.undo, name: name)
            postChange()
            prompts.showError("\(name) didn’t finish.", detail: partial.localizedDescription, in: window)
            return nil
        } catch {
            prompts.showError("\(name) failed.", detail: error.localizedDescription, in: window)
            return nil
        }
    }

    func registerUndo(_ record: UndoRecord, name: String) {
        undoManager.registerUndo(withTarget: self) { center in
            MainActor.assumeIsolated { center.applyUndo(record, name: name) }
        }
        undoManager.setActionName(name)
    }

    private func applyUndo(_ record: UndoRecord, name: String) {
        do {
            let redo = try ops.undo(record)
            registerUndo(redo, name: name)
        } catch let partial as PartialFailure {
            // Keep the reversed part redoable; report what couldn't be undone.
            registerUndo(partial.undo, name: name)
            prompts.showError("Couldn’t completely undo \(name).", detail: partial.localizedDescription, in: NSApp.keyWindow)
        } catch {
            prompts.showError("Couldn’t undo \(name).", detail: error.localizedDescription, in: NSApp.keyWindow)
        }
        postChange()
    }

    func postChange() {
        NotificationCenter.default.post(name: Self.filesDidChange, object: self)
    }

    // MARK: Transfers

    /// Copies or moves `sources` into `destination` in the background.
    func transfer(_ kind: TransferKind, _ sources: [URL], to destination: URL, window: NSWindow?,
                  completion: ((TransferResult) -> Void)? = nil) {
        guard !sources.isEmpty else { return }
        let t = Transfer(kind: kind, sources: sources, destination: destination)
        t.trash = ops.trash
        let job = TransferJob(transfer: t)
        let prompts = self.prompts
        t.resolveConflict = { [weak window] c in prompts.resolveConflict(c, in: window) }
        t.onProgress = { [weak self, weak job] p in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    job?.progress = p
                    self?.jobsChanged()
                }
            }
        }
        jobs.append(job)
        jobsChanged()

        let finish: (TransferResult) -> Void = { [weak self] result in
            guard let self else { return }
            job.isFinished = true
            self.jobs.removeAll { $0 === job }
            self.jobsChanged()
            let name = kind == .copy ? "Copy" : "Move"
            if let undo = result.undo, !undo.isEmpty { self.registerUndo(undo, name: name) }
            self.postChange()
            if !result.errors.isEmpty {
                self.prompts.showError("Some items couldn’t be \(kind == .copy ? "copied" : "moved").",
                                       detail: result.errors.joined(separator: "\n"), in: window)
            }
            completion?(result)
        }
        if runTransfersSynchronously {
            t.onProgress = nil
            finish(t.run())
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = t.run()
                DispatchQueue.main.async { MainActor.assumeIsolated { finish(result) } }
            }
        }
    }

    func cancelAll() {
        jobs.forEach { $0.transfer.cancel() }
    }

    private func jobsChanged() {
        NotificationCenter.default.post(name: Self.jobsDidChange, object: self)
    }
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
