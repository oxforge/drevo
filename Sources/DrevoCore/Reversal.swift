import Foundation

public struct ReversalResult: Sendable {
    /// Redoes the part that was reversed; nil when nothing was.
    public var redo: UndoRecord?
    /// Why it didn't finish; nil when it did, or when it was stopped.
    public var error: String?
    public var cancelled = false
}

/// Reverses an `UndoRecord` (an undo, or a redo: the reverse of an undo), run on a
/// background thread with progress and Stop. Moving an item back to another volume is a
/// copy followed by deleting the copy's source, which can take as long as the move it
/// undoes. Callbacks arrive on that thread.
public final class Reversal: @unchecked Sendable {
    public let record: UndoRecord
    public let trash: Trashing
    public var allowClone = true
    /// Which volume an item is on, as in `Transfer`; tests replace it to run the
    /// copy-then-delete path inside one temp folder.
    public var volumeOf: (URL) -> AnyHashable? = DropPolicy.volumeIdentifier(of:)
    public var onProgress: ((TransferProgress) -> Void)?

    private let cancellation = CancellationToken()
    private var throttle = ProgressThrottle()
    private var progress = TransferProgress()
    /// Bytes of each item that has to be copied to another volume, by its path.
    private var copySizes: [String: Int64] = [:]

    public init(_ record: UndoRecord, trash: Trashing) {
        self.record = record
        self.trash = trash
    }

    public func cancel() { cancellation.cancel() }

    public var isCancelled: Bool { cancellation.isCancelled }

    /// Thrown between items once Stop was asked for.
    private struct Stopped: Error {}

    private var fm: FileManager { .default }

    /// Reverses the record. Whatever was reversed before an error or Stop stays reversed,
    /// and `redo` covers exactly that part.
    public func run() -> ReversalResult {
        var result = ReversalResult()
        // Measured only when someone watches: it walks every folder that will be copied.
        if onProgress != nil { measure(record) }
        report(force: true)
        do {
            result.redo = try reverse()
        } catch {
            var cause = error
            if let partial = error as? PartialFailure {
                result.redo = partial.undo
                cause = partial.error
            }
            if cause is Stopped || cause is CopyEngine.Cancelled {
                result.cancelled = true
            } else {
                result.error = cause.localizedDescription
            }
        }
        if result.redo?.isEmpty == true { result.redo = nil }
        report(force: true)
        return result
    }

    /// Reverses the record; returns the record that redoes it. If it fails or is stopped
    /// partway, throws `PartialFailure` whose `undo` redoes the part that was reversed.
    func reverse() throws -> UndoRecord {
        try reverse(record)
    }

    private func reverse(_ record: UndoRecord) throws -> UndoRecord {
        switch record {
        case .created(let urls):
            var done: [TrashedItem] = []
            do {
                for url in urls {
                    try beginItem(url)
                    if FileIdentity.exists(url) {
                        done.append(TrashedItem(original: url, inTrash: try trash.trash(url)))
                    }
                    endItem()
                }
            } catch {
                if !done.isEmpty { throw PartialFailure(error: error, undo: .trashed(done)) }
                throw error
            }
            return .trashed(done)
        case .trashed(let items):
            var restored: [URL] = []
            do {
                for item in items {
                    try beginItem(item.original)
                    let dir = item.original.deletingLastPathComponent()
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    var dest = item.original
                    if FileIdentity.exists(dest) {
                        dest = dir.appendingPathComponent(UniqueName.numberedName(
                            for: dest.lastPathComponent, isFolder: UniqueName.isPlainFolder(item.inTrash), taken: UniqueName.takenIn(dir)))
                    }
                    try relocate(item.inTrash, to: dest)
                    restored.append(dest)
                    endItem()
                }
            } catch {
                if !restored.isEmpty { throw PartialFailure(error: error, undo: .created(restored)) }
                throw error
            }
            return .created(restored)
        case .moved(let items):
            var back: [MovedItem] = []
            do {
                for item in items.reversed() {
                    try beginItem(item.to)
                    try relocate(item.to, to: item.from)
                    back.append(MovedItem(from: item.to, to: item.from))
                    endItem()
                }
            } catch {
                if !back.isEmpty { throw PartialFailure(error: error, undo: .moved(back.reversed())) }
                throw error
            }
            return .moved(back.reversed())
        case .renamed(let from, let to):
            try beginItem(to)
            try fm.moveItem(at: to, to: from)
            endItem()
            return .renamed(from: to, to: from)
        case .group(let records):
            var redo: [UndoRecord] = []
            do {
                for r in records.reversed() { redo.append(try reverse(r)) }
            } catch let partial as PartialFailure {
                throw PartialFailure(error: partial.error, undo: .group(redo + [partial.undo]))
            } catch {
                if !redo.isEmpty { throw PartialFailure(error: error, undo: .group(redo)) }
                throw error
            }
            return .group(redo)
        }
    }

    // MARK: Moving one item

    /// True when moving `source` to `destination` can't be a rename. Unknown volumes count
    /// as one volume: `FileManager.moveItem` then does whatever is needed.
    private func crossesVolumes(_ source: URL, _ destination: URL) -> Bool {
        guard let from = volumeOf(source), let to = volumeOf(destination.deletingLastPathComponent()) else { return false }
        return from != to
    }

    /// Moves `source` to `destination` (which must not exist): a rename within a volume;
    /// across volumes a copy that reports progress and can be stopped, then deleting the
    /// source. A copy that is stopped or fails leaves nothing behind, so the item counts
    /// as not reversed.
    private func relocate(_ source: URL, to destination: URL) throws {
        guard crossesVolumes(source, destination) else {
            try fm.moveItem(at: source, to: destination)
            return
        }
        // copyfile would merge into an existing folder or overwrite a file.
        if FileIdentity.exists(destination) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        // Asked first, as in `Transfer`: deleting a folder empties it before the folder
        // itself turns out to be undeletable.
        guard fm.isDeletableFile(atPath: source.path) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: source.path])
        }
        let base = progress.completedBytes
        do {
            try CopyEngine.copy(source, to: destination, allowClone: allowClone) { copied in
                self.progress.completedBytes = base + copied
                self.report(force: false)
                return !self.isCancelled
            }
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
        progress.completedBytes = base + (copySizes[source.path] ?? 0)
        // The copy is complete; if the source can't be removed after all, the copy stays,
        // because by then it may be the only complete one.
        try fm.removeItem(at: source)
    }

    // MARK: Progress

    /// Counts the record's items, and the bytes of those that will be copied.
    private func measure(_ record: UndoRecord) {
        switch record {
        case .created(let urls):
            progress.totalItems += urls.count
        case .trashed(let items):
            for item in items { measureMove(item.inTrash, to: item.original) }
        case .moved(let items):
            for item in items { measureMove(item.to, to: item.from) }
        case .renamed:
            progress.totalItems += 1
        case .group(let records):
            records.forEach(measure)
        }
    }

    private func measureMove(_ source: URL, to destination: URL) {
        progress.totalItems += 1
        guard crossesVolumes(source, destination) else { return }
        let bytes = CopyEngine.measure(source, isCancelled: { isCancelled }).bytes
        copySizes[source.path] = bytes
        progress.totalBytes += bytes
    }

    /// Before each item: the place where Stop takes effect between items.
    private func beginItem(_ url: URL) throws {
        if isCancelled { throw Stopped() }
        progress.currentName = url.lastPathComponent
    }

    private func endItem() {
        progress.completedItems += 1
        report(force: false)
    }

    private func report(force: Bool) {
        guard let onProgress, force || throttle.isDue() else { return }
        onProgress(progress)
    }
}
