import Darwin
import Foundation

/// copyfile(3) wrapper: metadata-preserving, recursive, APFS clone when possible,
/// with byte progress and cancellation.
public enum CopyEngine {
    /// Called with bytes copied so far for this item; return false to cancel.
    public typealias Progress = (Int64) -> Bool

    final class Context {
        let progress: Progress?
        var finishedBytes: Int64 = 0
        var currentFile: Int64 = 0
        var cancelled = false
        init(progress: Progress?) { self.progress = progress }

        func report() -> Int32 {
            guard let progress else { return Int32(COPYFILE_CONTINUE) }
            if !progress(finishedBytes + currentFile) {
                cancelled = true
                return Int32(COPYFILE_QUIT)
            }
            return Int32(COPYFILE_CONTINUE)
        }
    }

    private static let callback: copyfile_callback_t = { what, stage, state, src, _, ctx in
        guard let ctx else { return Int32(COPYFILE_CONTINUE) }
        let c = Unmanaged<Context>.fromOpaque(ctx).takeUnretainedValue()
        switch (what, stage) {
        case (Int32(COPYFILE_COPY_DATA), Int32(COPYFILE_PROGRESS)):
            var copied: off_t = 0
            copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
            c.currentFile = Int64(copied)
            return c.report()
        case (Int32(COPYFILE_RECURSE_FILE), Int32(COPYFILE_FINISH)):
            var st = stat()
            if let src, lstat(src, &st) == 0 { c.finishedBytes += Int64(st.st_size) }
            c.currentFile = 0
            return c.report()
        case (_, Int32(COPYFILE_ERR)):
            return Int32(COPYFILE_QUIT)
        default:
            return c.cancelled ? Int32(COPYFILE_QUIT) : Int32(COPYFILE_CONTINUE)
        }
    }

    public struct Cancelled: Error {}

    /// Copies `source` to `destination` (which must not exist).
    public static func copy(_ source: URL, to destination: URL, allowClone: Bool, progress: Progress?) throws {
        let ctx = Context(progress: progress)
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        let unmanaged = Unmanaged.passRetained(ctx)
        defer { unmanaged.release() }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), unmanaged.toOpaque())

        var flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW_SRC)
        if allowClone { flags |= copyfile_flags_t(COPYFILE_CLONE) }
        let rc = copyfile(source.path, destination.path, state, flags)
        if rc != 0 {
            let code = errno
            if ctx.cancelled { throw Cancelled() }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                NSFilePathErrorKey: source.path,
                NSLocalizedDescriptionKey: "Couldn’t copy “\(source.lastPathComponent)”: \(String(cString: strerror(code)))",
            ])
        }
    }

    /// Bytes and item count under `url` (files only; folders count as items, no bytes).
    public static func measure(_ url: URL) -> (bytes: Int64, items: Int) {
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return (0, 1) }
        if values.isDirectory != true || values.isSymbolicLink == true {
            return (Int64(values.fileSize ?? 0), 1)
        }
        var bytes: Int64 = 0
        var items = 1
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) {
            for case let u as URL in e {
                items += 1
                let v = try? u.resourceValues(forKeys: [.fileSizeKey])
                bytes += Int64(v?.fileSize ?? 0)
            }
        }
        return (bytes, items)
    }
}

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
    public var onProgress: ((TransferProgress) -> Void)?
    public var resolveConflict: ((Conflict) -> ConflictDecision)?

    private let lock = NSLock()
    private var _cancelled = false
    private var lastReport = Date.distantPast

    public init(kind: TransferKind, sources: [URL], destination: URL) {
        self.kind = kind
        self.sources = sources
        self.destination = destination
    }

    public func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    public var title: String {
        let what = sources.count == 1 ? "“\(sources[0].lastPathComponent)”" : "\(sources.count) items"
        return "\(kind == .copy ? "Copying" : "Moving") \(what) to “\(destination.lastPathComponent)”"
    }

    // swiftlint:disable:next function_body_length
    public func run() -> TransferResult {
        let fm = FileManager.default
        var result = TransferResult()
        var progress = TransferProgress()
        let destVolume = DropPolicy.volumeIdentifier(of: destination)
        let plans = sources.map { src -> (URL, Bool, (bytes: Int64, items: Int)) in
            let sameVolume = DropPolicy.volumeIdentifier(of: src) == destVolume && destVolume != nil
            // Same-volume moves are renames: count items, not bytes.
            let size = kind == .move && sameVolume ? (Int64(0), 1) : CopyEngine.measure(src)
            return (src, sameVolume, size)
        }
        progress.totalBytes = plans.reduce(0) { $0 + $1.2.bytes }
        progress.totalItems = plans.count
        report(progress, force: true)

        var replaced: [TrashedItem] = []
        var created: [URL] = []
        var moved: [MovedItem] = []
        var standingDecision: ConflictAction?
        let conflictsTotal = plans.filter { fm.fileExists(atPath: destination.appendingPathComponent($0.0.lastPathComponent).path) }.count
        var conflictsSeen = 0

        for (source, sameVolume, size) in plans {
            if isCancelled { result.cancelled = true; break }
            let name = source.lastPathComponent
            progress.currentName = name
            report(progress, force: true)
            let isFolder = source.isDirectoryOnDisk

            if destination.isInside(source) {
                result.errors.append(FileOperationError.intoItself(name).localizedDescription)
                continue
            }
            var dest = destination.appendingPathComponent(name)
            let sameFolder = source.deletingLastPathComponent().standardizedFileURL.path == destination.standardizedFileURL.path

            if sameFolder {
                if kind == .move { result.skipped.append(source); progress.completedItems += 1; continue }
                dest = destination.appendingPathComponent(UniqueName.copyName(for: name, isFolder: isFolder, taken: UniqueName.takenIn(destination)))
            } else if fm.fileExists(atPath: dest.path) || (try? dest.checkResourceIsReachable()) == true || isSymlink(dest) {
                conflictsSeen += 1
                let action: ConflictAction
                if let standing = standingDecision {
                    action = standing
                } else {
                    let c = Conflict(source: source, existing: dest, sourceIsFolder: isFolder,
                                     existingIsFolder: dest.isDirectoryOnDisk, remaining: conflictsTotal - conflictsSeen)
                    let decision = resolveConflict?(c) ?? ConflictDecision(.stop)
                    if decision.applyToAll { standingDecision = decision.action }
                    action = decision.action
                }
                switch action {
                case .stop:
                    result.cancelled = true
                case .skip:
                    result.skipped.append(source)
                    progress.completedItems += 1
                    progress.completedBytes += size.bytes
                    continue
                case .keepBoth:
                    dest = destination.appendingPathComponent(UniqueName.numberedName(for: name, isFolder: isFolder, taken: UniqueName.takenIn(destination)))
                case .replace:
                    do {
                        replaced.append(TrashedItem(original: dest, inTrash: try trash.trash(dest)))
                    } catch {
                        result.errors.append("Couldn’t replace “\(name)”: \(error.localizedDescription)")
                        continue
                    }
                }
                if result.cancelled { break }
            }

            let base = progress.completedBytes
            do {
                if kind == .move && sameVolume {
                    try fm.moveItem(at: source, to: dest)
                    moved.append(MovedItem(from: source, to: dest))
                } else {
                    do {
                        try CopyEngine.copy(source, to: dest, allowClone: allowClone) { [weak self] copied in
                            guard let self else { return false }
                            progress.completedBytes = base + copied
                            self.report(progress, force: false)
                            return !self.isCancelled
                        }
                    } catch {
                        // Never leave a half-copied item behind; it didn't exist before.
                        try? fm.removeItem(at: dest)
                        throw error
                    }
                    if kind == .move {
                        try fm.removeItem(at: source)
                        moved.append(MovedItem(from: source, to: dest))
                    } else {
                        created.append(dest)
                    }
                }
                result.outputs.append(dest)
            } catch is CopyEngine.Cancelled {
                result.cancelled = true
                break
            } catch {
                result.errors.append((error as NSError).localizedDescription)
            }
            progress.completedBytes = base + size.bytes
            progress.completedItems += 1
            report(progress, force: true)
        }

        var steps: [UndoRecord] = []
        if !replaced.isEmpty { steps.append(.trashed(replaced)) }
        if !created.isEmpty { steps.append(.created(created)) }
        if !moved.isEmpty { steps.append(.moved(moved)) }
        result.undo = steps.isEmpty ? nil : (steps.count == 1 ? steps[0] : .group(steps))
        return result
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    /// At most ~30 updates a second unless forced.
    private func report(_ p: TransferProgress, force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) > 0.033 else { return }
        lastReport = now
        onProgress?(p)
    }
}
