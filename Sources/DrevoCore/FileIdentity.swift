import Darwin
import Foundation

/// Device + inode: the same item no matter which path reaches it.
public struct FileIdentity: Hashable, Sendable {
    public let device: dev_t
    public let inode: ino_t

    public static func of(_ url: URL, followLinks: Bool) -> FileIdentity? {
        var st = stat()
        let rc = followLinks ? stat(url.path, &st) : lstat(url.path, &st)
        return rc == 0 ? FileIdentity(device: st.st_dev, inode: st.st_ino) : nil
    }

    /// True if anything is at `url`, including a broken symlink.
    public static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    /// True if both URLs reach the same item: /tmp and /private/tmp, a folder and a link
    /// to it (unless `followLinks` is false), "Docs" and "docs" on a case-insensitive
    /// volume. If one of them isn't on disk there is nothing to compare but the paths.
    public static func sameItem(_ a: URL, _ b: URL, followLinks: Bool = true) -> Bool {
        guard let first = of(a, followLinks: followLinks), let second = of(b, followLinks: followLinks) else {
            return a.standardizedFileURL.path == b.standardizedFileURL.path
        }
        return first == second
    }
}
