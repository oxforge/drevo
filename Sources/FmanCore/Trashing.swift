import Foundation

/// Moves items to a trash. The system one in the app; a folder in tests.
public protocol Trashing: Sendable {
    /// Returns where the item ended up.
    func trash(_ url: URL) throws -> URL
}

public struct SystemTrash: Trashing {
    public init() {}
    public func trash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return (result as URL?) ?? url
    }
}

/// A plain folder standing in for the Trash (tests, previews).
public struct FolderTrash: Trashing {
    public let folder: URL
    public init(folder: URL) { self.folder = folder }
    public func trash(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = UniqueName.numberedName(for: url.lastPathComponent, isFolder: UniqueName.isPlainFolder(url),
                                           taken: UniqueName.takenIn(folder))
        let dest = folder.appendingPathComponent(name)
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }
}
