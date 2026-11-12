import Darwin
import Foundation

public struct TransferProgress: Sendable, Equatable {
    public var totalBytes: Int64 = 0
    public var completedBytes: Int64 = 0
    public var totalItems = 0
    public var completedItems = 0
    public var currentName = ""

    public init() {}

    public var fraction: Double {
        if totalBytes > 0 { return min(1, Double(completedBytes) / Double(totalBytes)) }
        return totalItems > 0 ? Double(completedItems) / Double(totalItems) : 0
    }
}

public struct Conflict: Sendable, Equatable {
    public let source: URL
    public let existing: URL
    public let sourceIsFolder: Bool
    public let existingIsFolder: Bool
    /// Conflicts left after this one (for "Apply to all").
    public let remaining: Int
}

public enum ConflictAction: Sendable, Equatable {
    case replace, keepBoth, skip, stop
}

public struct ConflictDecision: Sendable, Equatable {
    public let action: ConflictAction
    public let applyToAll: Bool
    public init(_ action: ConflictAction, applyToAll: Bool = false) {
        self.action = action
        self.applyToAll = applyToAll
    }
}

public struct TransferResult: Sendable {
    public var undo: UndoRecord?
    /// Where each copied or moved item ended up.
    public var outputs: [URL] = []
    public var skipped: [URL] = []
    public var errors: [String] = []
    public var cancelled = false
}

/// A copy or move of several items into a folder, run on a background thread.
/// Callbacks arrive on that thread; `resolveConflict` may block until the user answers.
public final class Transfer: @unchecked Sendable {
    public let kind: TransferKind
    public let sources: [URL]
    public let destination: URL
    public var allowClone = true
    public var trash: Trashing = SystemTrash()
    /// Which volume an item is on. A move within one volume is a rename; across volumes it
    /// is a copy followed by deleting the source. Tests replace this to run the second path
    /// inside one temp folder.
    public var volumeOf: (URL) -> AnyHashable? = DropPolicy.volumeIdentifier(of:)
    public var onProgress: ((TransferProgress) -> Void)?
    public var resolveConflict: ((Conflict) -> ConflictDecision)?

    private let cancellation = CancellationToken()
    private var lastReport = Date.distantPast

    public init(kind: TransferKind, sources: [URL], destination: URL) {
        self.kind = kind
        self.sources = sources
        self.destination = destination
    }

    public func cancel() { cancellation.cancel() }

    public var isCancelled: Bool { cancellation.isCancelled }

    public var title: String {
        let what = sources.count == 1 ? "“\(sources[0].lastPathComponent)”" : "\(sources.count) items"
        return "\(kind == .copy ? "Copying" : "Moving") \(what) to “\(destination.lastPathComponent)”"
    }

    // MARK: Running

    /// One source, with what is known about it before anything is copied.
    private struct Item {
        let source: URL
        /// A move within one volume: the item is renamed into place, nothing is copied.
        let byRename: Bool
        let size: (bytes: Int64, items: Int)
        var name: String { source.lastPathComponent }
    }

    /// What `run` remembers between items while it decides where each one goes.
    private struct DestinationState {
        /// The destination by identity, not by path: two panes can show one folder through
        /// /tmp and /private/tmp, a symlink, or different letter case.
        let folderID: FileIdentity?
        /// The destination's names, read once rather than for every item that needs a new one.
        let names = UniqueName.TakenNames()
        let conflictsTotal: Int
        var conflictsSeen = 0
        /// The answer given with "Apply to all".
        var standingDecision: ConflictAction?
    }

    /// Where an item goes, or why it goes nowhere.
    private enum Resolution {
        /// Put it at `url`. With `replacing` set, `url` is a temporary name next to the item
        /// to replace, which stays until the new one is complete.
        case place(at: URL, replacing: URL?)
        case skip
        case refuse(String)
        /// The user chose Stop: end the whole transfer.
        case stop
    }

    /// What was changed, for undo.
    private struct Changes {
        var replaced: [TrashedItem] = []
        var created: [URL] = []
        var moved: [MovedItem] = []

        var undoRecord: UndoRecord? {
            var steps: [UndoRecord] = []
            if !replaced.isEmpty { steps.append(.trashed(replaced)) }
            if !created.isEmpty { steps.append(.created(created)) }
            if !moved.isEmpty { steps.append(.moved(moved)) }
            return steps.isEmpty ? nil : (steps.count == 1 ? steps[0] : .group(steps))
        }
    }

    private var fm: FileManager { .default }

    public func run() -> TransferResult {
        var result = TransferResult()
        var progress = TransferProgress()
        let items = plan()
        progress.totalBytes = items.reduce(0) { $0 + $1.size.bytes }
        progress.totalItems = items.count
        report(progress, force: true)

        var changes = Changes()
        var state = DestinationState(
            folderID: FileIdentity.of(destination, followLinks: true),
            conflictsTotal: items.filter { FileIdentity.exists(destination.appendingPathComponent($0.name)) }.count)

        items: for item in items {
            if isCancelled { result.cancelled = true; break }
            progress.currentName = item.name
            report(progress, force: true)
            let base = progress.completedBytes

            switch resolveDestination(for: item, &state) {
            case .stop:
                result.cancelled = true
                break items
            case .skip:
                result.skipped.append(item.source)
            case .refuse(let reason):
                result.errors.append(reason)
            case .place(var url, let replacing):
                do {
                    try place(item, at: url) { copied in
                        progress.completedBytes = base + copied
                        self.report(progress, force: false)
                    }
                    if let replacing {
                        changes.replaced.append(try swapIn(url, replacing: replacing, item))
                        url = replacing
                    }
                    if kind == .copy {
                        changes.created.append(url)
                    } else if let problem = removeCopiedSource(item) {
                        // The copy is complete, so the item counts as copied: undo removes
                        // the copy, and the pane selects it.
                        changes.created.append(url)
                        result.errors.append(problem)
                    } else {
                        changes.moved.append(MovedItem(from: item.source, to: url))
                    }
                    result.outputs.append(url)
                } catch is CopyEngine.Cancelled {
                    result.cancelled = true
                    break items
                } catch {
                    result.errors.append((error as NSError).localizedDescription)
                }
            }
            // Every item that was dealt with counts as done: copied, skipped, refused or failed.
            progress.completedBytes = base + item.size.bytes
            progress.completedItems += 1
            report(progress, force: true)
        }

        result.undo = changes.undoRecord
        return result
    }

    private func plan() -> [Item] {
        let destinationVolume = volumeOf(destination)
        return sources.map { source in
            let sameVolume = destinationVolume != nil && volumeOf(source) == destinationVolume
            let byRename = kind == .move && sameVolume
            // Renames count items, not bytes.
            let size = byRename ? (Int64(0), 1) : CopyEngine.measure(source, isCancelled: { isCancelled })
            return Item(source: source, byRename: byRename, size: size)
        }
    }

    // MARK: Steps for one item

    /// Decides where `item` goes: its own name, a new name when it is copied into the folder
    /// it is already in, or whatever the user answers when the name is taken.
    private func resolveDestination(for item: Item, _ state: inout DestinationState) -> Resolution {
        let source = item.source
        if destination.isInside(source) {
            return .refuse(FileOperationError.intoItself(item.name).localizedDescription)
        }
        let plain = destination.appendingPathComponent(item.name)
        let exists = FileIdentity.exists(plain)

        let sourceFolderID = FileIdentity.of(source.deletingLastPathComponent(), followLinks: true)
        // Already in the destination — or the "existing" item is the source itself, reached
        // another way. Never a conflict: the source must not be offered for replacing.
        let alreadyThere = (sourceFolderID != nil && sourceFolderID == state.folderID)
            || (exists && FileIdentity.of(plain, followLinks: false) == FileIdentity.of(source, followLinks: false))
        if alreadyThere {
            guard kind == .copy else { return .skip }
            return .place(at: newName(UniqueName.copyName, for: source, &state), replacing: nil)
        }
        guard exists else { return .place(at: plain, replacing: nil) }

        switch conflictAction(for: item, existing: plain, &state) {
        case .stop:
            return .stop
        case .skip:
            return .skip
        case .keepBoth:
            return .place(at: newName(UniqueName.numberedName, for: source, &state), replacing: nil)
        case .replace:
            if source.isInside(plain) {
                return .refuse("Can’t replace “\(item.name)” with an item it contains.")
            }
            // A short temporary name of its own: one built from the item's name would pass
            // the 255-byte limit for long names.
            return .place(at: destination.appendingPathComponent(".fman-\(UUID().uuidString)"), replacing: plain)
        }
    }

    /// A free name in the destination ("x copy" or "x 2"), remembered so the next item
    /// doesn't get the same one.
    private func newName(_ scheme: (String, Bool, (String) -> Bool) -> String, for source: URL,
                         _ state: inout DestinationState) -> URL {
        let name = scheme(source.lastPathComponent, UniqueName.isPlainFolder(source), state.names.taken(in: destination))
        state.names.add(name, in: destination)
        return destination.appendingPathComponent(name)
    }

    /// The standing "Apply to all" answer, or the user's answer for this item.
    private func conflictAction(for item: Item, existing: URL, _ state: inout DestinationState) -> ConflictAction {
        state.conflictsSeen += 1
        if let standing = state.standingDecision { return standing }
        let conflict = Conflict(source: item.source, existing: existing, sourceIsFolder: item.source.isDirectoryOnDisk,
                                existingIsFolder: existing.isDirectoryOnDisk,
                                remaining: state.conflictsTotal - state.conflictsSeen)
        let decision = resolveConflict?(conflict) ?? ConflictDecision(.stop)
        if decision.applyToAll { state.standingDecision = decision.action }
        return decision.action
    }

    /// Puts the item at `url`: a rename, or a copy that reports the bytes copied so far.
    private func place(_ item: Item, at url: URL, copied: @escaping (Int64) -> Void) throws {
        if item.byRename {
            try fm.moveItem(at: item.source, to: url)
            return
        }
        do {
            try CopyEngine.copy(item.source, to: url, allowClone: allowClone) { bytes in
                copied(bytes)
                return !self.isCancelled
            }
        } catch {
            // Never leave a half-copied item behind; it didn't exist before.
            try? fm.removeItem(at: url)
            throw error
        }
    }

    /// Replace, second half: the new item is complete at `staged`, so only now does the old
    /// one go to the Trash and the new one take its name. If either step fails, the old
    /// item is put back and the staged one is undone.
    private func swapIn(_ staged: URL, replacing old: URL, _ item: Item) throws -> TrashedItem {
        var inTrash: URL?
        do {
            let trashed = try trash.trash(old)
            inTrash = trashed
            try fm.moveItem(at: staged, to: old)
            return TrashedItem(original: old, inTrash: trashed)
        } catch {
            if let inTrash { try? fm.moveItem(at: inTrash, to: old) }
            if item.byRename { try? fm.moveItem(at: staged, to: item.source) } else { try? fm.removeItem(at: staged) }
            throw error
        }
    }

    /// The last step of a move across volumes, after everything else succeeded: deletes the
    /// source. Returns what to tell the user if it can't be deleted (read-only disk, no
    /// permission); nil when the source is gone, which a rename has done already.
    private func removeCopiedSource(_ item: Item) -> String? {
        guard !item.byRename else { return nil }
        let notRemoved = "“\(item.name)” was copied, but the original couldn’t be removed."
        // Asked first, because trying isn't harmless: deleting a folder empties it before
        // the folder itself turns out to be undeletable, which would leave half an
        // original while undo takes away the only complete copy.
        guard fm.isDeletableFile(atPath: item.source.path) else {
            return notRemoved + " You don’t have permission to delete it, or its disk is read-only."
        }
        do {
            try fm.removeItem(at: item.source)
            return nil
        } catch {
            let ns = error as NSError
            let reason = ns.localizedFailureReason ?? (ns.userInfo[NSUnderlyingErrorKey] as? NSError)?.localizedDescription ?? ns.localizedDescription
            return notRemoved + " " + reason
        }
    }

    /// Byte updates at most ~30 a second; item boundaries (forced) always report and
    /// don't delay the next byte update.
    private func report(_ p: TransferProgress, force: Bool) {
        if !force {
            let now = Date()
            guard now.timeIntervalSince(lastReport) > 0.033 else { return }
            lastReport = now
        }
        onProgress?(p)
    }
}
