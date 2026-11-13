import Darwin
import Foundation

public struct DeletionResult: Sendable {
    public var errors: [String] = []
    /// Stopped before everything was deleted; what was left is still in place.
    public var cancelled = false
}

/// Deletes items for good (no Trash, no undo), run on a background thread. A folder is
/// emptied entry by entry rather than with one `removeItem`, so that a large tree shows
/// progress and can be stopped. Callbacks arrive on that thread.
public final class Deletion: @unchecked Sendable {
    public let items: [URL]
    public var onProgress: ((TransferProgress) -> Void)?

    private let cancellation = CancellationToken()
    private var throttle = ProgressThrottle()
    private var progress = TransferProgress()

    public init(_ items: [URL]) {
        self.items = items
    }

    public func cancel() { cancellation.cancel() }

    public var isCancelled: Bool { cancellation.isCancelled }

    public var title: String {
        "Deleting " + (items.count == 1 ? "“\(items[0].lastPathComponent)”" : "\(items.count) items")
    }

    private struct Stopped: Error {}

    private var fm: FileManager { .default }

    /// Deletes the items in order. One that can't be deleted is reported and the rest go
    /// on; Stop ends the run without an error, leaving what wasn't reached yet.
    public func run() -> DeletionResult {
        var result = DeletionResult()
        // Counted first (only when someone watches), so the bar can show how far it is.
        if onProgress != nil {
            progress.totalItems = items.reduce(0) { $0 + CopyEngine.measure($1, isCancelled: { isCancelled }).items }
        }
        report(force: true)
        for item in items {
            progress.currentName = item.lastPathComponent
            report(force: true)
            do {
                try remove(item)
            } catch is Stopped {
                result.cancelled = true
                break
            } catch {
                result.errors.append((error as NSError).localizedDescription)
            }
        }
        report(force: true)
        return result
    }

    /// Removes `url` and, for a folder, everything in it first. A link to a folder is
    /// removed as a link: what it points to is not touched.
    private func remove(_ url: URL) throws {
        if isCancelled { throw Stopped() }
        if Self.isRealDirectory(url) {
            for name in try fm.contentsOfDirectory(atPath: url.path) {
                // The hint saves URL a look at the disk for every entry.
                try remove(url.appendingPathComponent(name, isDirectory: false))
            }
        }
        try fm.removeItem(at: url)
        progress.completedItems += 1
        report(force: false)
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    private func report(force: Bool) {
        guard let onProgress, force || throttle.isDue() else { return }
        onProgress(progress)
    }
}
