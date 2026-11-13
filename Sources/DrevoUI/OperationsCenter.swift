import AppKit
import DrevoCore

/// Runs file operations for every window: undo/redo, background jobs, refresh.
@MainActor
final class OperationsCenter {
    static let filesDidChange = Notification.Name("drevo.filesDidChange")
    static let jobsDidChange = Notification.Name("drevo.jobsDidChange")

    let ops: FileOperations
    let undoManager = FileUndoManager()
    var prompts: UserPrompts
    /// Tests run background jobs (transfers, deletes, undo and redo) inline so results are
    /// visible right after the call.
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

    func postChange() {
        NotificationCenter.default.post(name: Self.filesDidChange, object: self)
    }

    // MARK: Undo

    func registerUndo(_ record: UndoRecord, name: String) {
        register(UndoSlot(.ready(record)), name: name)
    }

    private func register(_ slot: UndoSlot, name: String) {
        slot.isRegistered = true
        // The undo manager doesn't retain its target, so the handler holds the slot.
        undoManager.registerUndo(withTarget: slot) { [weak self, slot] _ in
            MainActor.assumeIsolated { self?.reverse(slot, name: name) }
        }
        undoManager.setActionName(name)
    }

    /// Undoes (or redoes) the record in `slot` in the background, as a job with progress
    /// and Stop. The undo manager puts an action on the opposite stack only while it is
    /// still undoing, so the opposite action is registered right away, with a slot that
    /// gets its record when the work is done. Until then `undoManager` refuses to undo or
    /// redo: the next ⌘Z can't start out of order or find a slot that is still empty.
    private func reverse(_ slot: UndoSlot, name: String) {
        guard case .ready(let record) = slot.state else { return }
        let redoing = undoManager.isRedoing
        let reversal = Reversal(record, trash: ops.trash)
        let job = TransferJob(title: "\(redoing ? "Redoing" : "Undoing") \(name)") { reversal.cancel() }
        reversal.onProgress = progressUpdates(for: job)
        let opposite = UndoSlot(.waiting)
        undoManager.isReversing = true
        run(job, { reversal.run() }) { [weak self] result in
            guard let self else { return }
            self.undoManager.isReversing = false
            if let redo = result.redo {
                // Also after an error or Stop: the part that was reversed stays redoable.
                opposite.state = .ready(redo)
            } else {
                opposite.state = .nothing
                if opposite.isRegistered { self.undoManager.removeAllActions(withTarget: opposite) }
            }
            self.postChange()
            if let error = result.error {
                let verb = redoing ? "redo" : "undo"
                self.prompts.showError(result.redo == nil ? "Couldn’t \(verb) \(name)." : "Couldn’t completely \(verb) \(name).",
                                       detail: error, in: NSApp.keyWindow)
            }
        }
        // Run inline (tests), it is known by now whether anything was reversed.
        if case .nothing = opposite.state { return }
        register(opposite, name: name)
    }

    // MARK: Transfers

    /// Copies or moves `sources` into `destination` in the background.
    func transfer(_ kind: TransferKind, _ sources: [URL], to destination: URL, window: NSWindow?,
                  completion: ((TransferResult) -> Void)? = nil) {
        guard !sources.isEmpty else { return }
        let t = Transfer(kind: kind, sources: sources, destination: destination)
        start(t, title: t.title, undoName: kind == .copy ? "Copy" : "Move",
              failure: "Some items couldn’t be \(kind == .copy ? "copied" : "moved").", window: window, completion: completion)
    }

    /// Makes "x copy" next to each item in the background: a copy into the item's own
    /// folder, which names the copies as Finder does. `completion` is called once for
    /// every folder the items are in (a pane's selection is in one).
    func duplicate(_ urls: [URL], window: NSWindow?, completion: ((TransferResult) -> Void)? = nil) {
        var folders: [URL] = []
        var byFolder: [String: [URL]] = [:]
        for url in urls {
            let folder = url.deletingLastPathComponent()
            if byFolder[folder.path] == nil { folders.append(folder) }
            byFolder[folder.path, default: []].append(url)
        }
        for folder in folders {
            let sources = byFolder[folder.path] ?? []
            let what = sources.count == 1 ? "“\(sources[0].lastPathComponent)”" : "\(sources.count) items"
            start(Transfer(kind: .copy, sources: sources, destination: folder), title: "Duplicating \(what)",
                  undoName: "Duplicate", failure: "Some items couldn’t be duplicated.", window: window, completion: completion)
        }
    }

    private func start(_ t: Transfer, title: String, undoName: String, failure: String, window: NSWindow?,
                       completion: ((TransferResult) -> Void)?) {
        t.trash = ops.trash
        let job = TransferJob(title: title) { t.cancel() }
        let prompts = self.prompts
        t.resolveConflict = { [weak window] c in prompts.resolveConflict(c, in: window) }
        t.onProgress = progressUpdates(for: job)
        run(job, { t.run() }) { [weak self] result in
            guard let self else { return }
            if let undo = result.undo, !undo.isEmpty { self.registerUndo(undo, name: undoName) }
            self.postChange()
            if !result.errors.isEmpty {
                self.prompts.showError(failure, detail: result.errors.joined(separator: "\n"), in: window)
            }
            completion?(result)
        }
    }

    // MARK: Delete

    /// Deletes `urls` for good in the background. There is no undo; Stop leaves what
    /// wasn't deleted yet in place and is not reported as an error.
    func delete(_ urls: [URL], window: NSWindow?, completion: ((DeletionResult) -> Void)? = nil) {
        guard !urls.isEmpty else { return }
        let deletion = Deletion(urls)
        let job = TransferJob(title: deletion.title) { deletion.cancel() }
        deletion.onProgress = progressUpdates(for: job)
        run(job, { deletion.run() }) { [weak self] result in
            guard let self else { return }
            self.postChange()
            if !result.errors.isEmpty {
                self.prompts.showError("Some items couldn’t be deleted.", detail: result.errors.joined(separator: "\n"), in: window)
            }
            completion?(result)
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
        run(job, work) { [weak self] result in
            guard let self else { return }
            if !result.outputs.isEmpty { self.registerUndo(.created(result.outputs), name: "Expand") }
            self.postChange()
            if !result.errors.isEmpty {
                self.prompts.showError("Some archives couldn’t be expanded.", detail: result.errors.joined(separator: "\n"), in: window)
            }
            completion?(result.outputs)
        }
    }

    // MARK: Jobs

    /// Lists `job` and runs `work` for it off the main thread; `finish` gets the result on
    /// the main run loop once the job is off the list. Tests run it all inline.
    private func run<Result>(_ job: TransferJob, _ work: @escaping @Sendable () -> Result,
                             then finish: @escaping @MainActor (Result) -> Void) {
        jobs.append(job)
        jobsChanged()
        let done: @MainActor (Result) -> Void = { [weak self] result in
            self?.jobs.removeAll { $0 === job }
            self?.jobsChanged()
            finish(result)
        }
        if runTransfersSynchronously {
            done(work())
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = work()
                onMainRunLoop { done(result) }
            }
        }
    }

    /// Where a background operation sends its progress: to its job, on the main run loop.
    /// Nothing watches an operation that runs inline.
    private func progressUpdates(for job: TransferJob) -> ((TransferProgress) -> Void)? {
        guard !runTransfersSynchronously else { return nil }
        return { [weak self, weak job] progress in
            onMainRunLoop {
                job?.progress = progress
                self?.jobsChanged()
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

/// A place on the undo or redo stack. An undo runs in the background, but its redo has to
/// be registered while the undo manager is still undoing, before the redo record exists:
/// the slot is registered then, and gets the record when the undo has finished.
@MainActor
private final class UndoSlot {
    enum State {
        /// The operation that will fill the slot is still running.
        case waiting
        case ready(UndoRecord)
        /// Nothing was reversed, so there is nothing to redo.
        case nothing
    }

    var state: State
    /// Whether the slot was put on one of the undo manager's stacks.
    var isRegistered = false

    init(_ state: State) { self.state = state }
}

/// The undo manager for file operations: it stands still while an undo or redo runs in
/// the background. A second ⌘Z would otherwise start before the first has finished and
/// filled in its redo, and the two would run out of order.
final class FileUndoManager: UndoManager {
    var isReversing = false

    override var canUndo: Bool { !isReversing && super.canUndo }
    override var canRedo: Bool { !isReversing && super.canRedo }

    override func undo() {
        if !isReversing { super.undo() }
    }

    override func redo() {
        if !isReversing { super.redo() }
    }
}
