import Foundation

extension URL {
    /// Real directory test (URL.hasDirectoryPath only reflects a trailing slash).
    public var isDirectoryOnDisk: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// True if `self` is `other` or inside it. `other` itself isn't followed if it's a
    /// symlink: a link is copied or moved as a link, so copying it into its target is fine.
    ///
    /// Items are compared by identity, not by path text, so /tmp and /private/tmp, links on
    /// the way and letter case all give the answer the volume would. Parts of `self` that
    /// don't exist yet (a destination typed by hand) are inside whatever holds their
    /// nearest existing ancestor.
    public func isInside(_ other: URL) -> Bool {
        let other = other.standardizedFileURL
        guard let container = FileIdentity.of(other, followLinks: false) else {
            // Nothing on disk to compare with; the path text is all there is.
            return standardizedFileURL.pathComponents.starts(with: other.pathComponents)
        }
        return isOrIsHeld { $0 == container }
    }

    /// True if `match` accepts `self` or one of the folders that hold it, as the volume
    /// sees them (see `isInside`). Asking this once for a whole set of candidate
    /// containers costs one walk up the path, however many candidates there are.
    public func isOrIsHeld(by match: (FileIdentity) -> Bool) -> Bool {
        // The physical path of `self` (or of its nearest existing ancestor): every
        // component is a real folder, so walking up it visits each folder that holds it.
        var path = standardizedFileURL.path
        var physical = Self.physicalPath(path)
        while physical == nil, path != "/" {
            path = (path as NSString).deletingLastPathComponent
            physical = Self.physicalPath(path)
        }
        guard var ancestor = physical else { return false }
        while true {
            if let id = FileIdentity.of(URL(fileURLWithPath: ancestor, isDirectory: true), followLinks: false), match(id) { return true }
            if ancestor == "/" { return false }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
    }

    /// realpath(3): nil if the item doesn't exist (or is a link to nothing).
    private static func physicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
