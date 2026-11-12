import AppKit
import FmanCore

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
            onMainRunLoop {
                job?.progress = p
                self?.jobsChanged()
            }
        }
        jobs.append(job)
        jobsChanged()

        let finish: (TransferResult) -> Void = { [weak self] result in
            guard let self else { return }
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
                onMainRunLoop { finish(result) }
            }
        }
    }

    // MARK: Archives

    /// Expands archives next to themselves in the background (no Archive Utility, so no
    /// Finder window pops up); `completion` gets what was created.
    func extract(_ archives: [URL], window: NSWindow?, completion: (([URL]) -> Void)? = nil) {
        let extractions = archives.compactMap(ArchiveExtraction.init(archive:))
        guard !extractions.isEmpty else { return }
        let title = extractions.count == 1 ? "Expanding “\(extractions[0].archive.lastPathComponent)”" : "Expanding \(extractions.count) archives"
        let job = TransferJob(title: title) { extractions.forEach { $0.cancel() } }
        job.progress.totalItems = extractions.count
        jobs.append(job)
        jobsChanged()

        let work: @Sendable () -> (outputs: [URL], errors: [String]) = { [weak self] in
            var outputs: [URL] = []
            var errors: [String] = []
            for (i, extraction) in extractions.enumerated() {
                do {
                    outputs += try extraction.run()
                } catch is ArchiveExtraction.Cancelled {
                    break
                } catch {
                    errors.append(error.localizedDescription)
                }
                onMainRunLoop {
                    job.progress.completedItems = i + 1
                    job.progress.currentName = extraction.archive.lastPathComponent
                    self?.jobsChanged()
                }
            }
            return (outputs, errors)
        }
        let finish: (([URL], [String])) -> Void = { [weak self] result in
            guard let self else { return }
            self.jobs.removeAll { $0 === job }
            self.jobsChanged()
            if !result.0.isEmpty { self.registerUndo(.created(result.0), name: "Expand") }
            self.postChange()
            if !result.1.isEmpty {
                self.prompts.showError("Some archives couldn’t be expanded.", detail: result.1.joined(separator: "\n"), in: window)
            }
            completion?(result.0)
        }
        if runTransfersSynchronously {
            finish(work())
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = work()
                onMainRunLoop { finish(result) }
            }
        }
    }

    func cancelAll() {
        jobs.forEach { $0.cancel() }
    }

    private func jobsChanged() {
        NotificationCenter.default.post(name: Self.jobsDidChange, object: self)
    }
}
