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
    /// `isCancelled` is asked before each entry; once it says yes the walk stops and the
    /// totals cover only what was seen so far, so check the flag before using them.
    public static func measure(_ url: URL, isCancelled: () -> Bool = { false }) -> (bytes: Int64, items: Int) {
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return (0, 1) }
        if values.isDirectory != true || values.isSymbolicLink == true {
            return (Int64(values.fileSize ?? 0), 1)
        }
        var bytes: Int64 = 0
        var items = 1
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) {
            for case let u as URL in e {
                if isCancelled() { break }
                items += 1
                let v = try? u.resourceValues(forKeys: [.fileSizeKey])
                bytes += Int64(v?.fileSize ?? 0)
            }
        }
        return (bytes, items)
    }
}
