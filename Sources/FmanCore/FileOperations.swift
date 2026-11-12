import Foundation

/// How to undo a file operation. Undoing a record returns the record that redoes it.
public indirect enum UndoRecord: Equatable, Sendable {
    /// Items that didn't exist before (copies, new folders). Undo: move them to the Trash.
    case created([URL])
    /// Items moved to the Trash: (original location, location in the Trash). Undo: put back.
    case trashed([TrashedItem])
    /// Items moved. Undo: move each back.
    case moved([MovedItem])
    case renamed(from: URL, to: URL)
    /// Several steps; undone in reverse order.
    case group([UndoRecord])

    public var isEmpty: Bool {
        switch self {
        case .created(let u): return u.isEmpty
        case .trashed(let t): return t.isEmpty
        case .moved(let m): return m.isEmpty
        case .renamed: return false
        case .group(let g): return g.allSatisfy(\.isEmpty)
        }
    }
}

public struct TrashedItem: Equatable, Sendable {
    public let original: URL
    public let inTrash: URL
    public init(original: URL, inTrash: URL) { self.original = original; self.inTrash = inTrash }
}

public struct MovedItem: Equatable, Sendable {
    public let from: URL
    public let to: URL
    public init(from: URL, to: URL) { self.from = from; self.to = to }
}

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
        let name = UniqueName.numberedName(for: url.lastPathComponent, isFolder: url.hasDirectoryPath,
                                           taken: UniqueName.takenIn(folder))
        let dest = folder.appendingPathComponent(name)
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }
}

public enum FileOperationError: LocalizedError, Equatable {
    case invalidName(String)
    case nameTaken(String)
    case intoItself(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let why): return why
        case .nameTaken(let name): return "The name “\(name)” is already taken. Please choose a different name."
        case .intoItself(let name): return "Can’t copy or move “\(name)” into itself."
        case .notFound(let name): return "“\(name)” can’t be found."
        }
    }
}

/// Single-step file operations (fast, synchronous). Copy/move with progress live in `Transfer`.
public struct FileOperations: Sendable {
    public let trash: Trashing

    public init(trash: Trashing = SystemTrash()) {
        self.trash = trash
    }

    private var fm: FileManager { .default }

    // MARK: Create

    /// Creates "untitled folder" (or `name`) in `directory`.
    public func makeFolder(in directory: URL, name: String? = nil) throws -> (URL, UndoRecord) {
        let finalName = try name.map { try Self.validate(name: $0) } ?? UniqueName.newFolderName(taken: UniqueName.takenIn(directory))
        let url = directory.appendingPathComponent(finalName, isDirectory: true)
        if fm.fileExists(atPath: url.path) { throw FileOperationError.nameTaken(finalName) }
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return (url, .created([url]))
    }

    /// Creates an empty "untitled.txt" (or `name`) in `directory`.
    public func makeFile(in directory: URL, name: String? = nil) throws -> (URL, UndoRecord) {
        let finalName = try name.map { try Self.validate(name: $0) }
            ?? UniqueName.numberedName(for: "untitled.txt", isFolder: false, taken: UniqueName.takenIn(directory))
        let url = directory.appendingPathComponent(finalName)
        if fm.fileExists(atPath: url.path) { throw FileOperationError.nameTaken(finalName) }
        guard fm.createFile(atPath: url.path, contents: Data()) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return (url, .created([url]))
    }

    // MARK: Rename

    /// Rejects names Finder rejects; returns the trimmed name.
    public static func validate(name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw FileOperationError.invalidName("A name can’t be empty.") }
        if trimmed.contains("/") { throw FileOperationError.invalidName("A name can’t contain “/”.") }
        if trimmed == "." || trimmed == ".." { throw FileOperationError.invalidName("“\(trimmed)” is reserved by the system.") }
        if trimmed.utf8.count > 255 { throw FileOperationError.invalidName("The name is too long.") }
        return trimmed
    }

    public func rename(_ url: URL, to newName: String) throws -> (URL, UndoRecord?) {
        let name = try Self.validate(name: newName)
        if name == url.lastPathComponent { return (url, nil) }
        let dest = url.deletingLastPathComponent().appendingPathComponent(name)
        let caseOnly = name.lowercased() == url.lastPathComponent.lowercased()
        if !caseOnly, fm.fileExists(atPath: dest.path) { throw FileOperationError.nameTaken(name) }
        try fm.moveItem(at: url, to: dest)
        return (dest, .renamed(from: url, to: dest))
    }

    // MARK: Trash / delete

    public func moveToTrash(_ urls: [URL]) throws -> UndoRecord {
        var done: [TrashedItem] = []
        do {
            for url in urls {
                done.append(TrashedItem(original: url, inTrash: try trash.trash(url)))
            }
        } catch {
            if !done.isEmpty { throw PartialFailure(error: error, undo: .trashed(done)) }
            throw error
        }
        return .trashed(done)
    }

    /// Permanent; there is no undo.
    public func deleteImmediately(_ urls: [URL]) throws {
        for url in urls { try fm.removeItem(at: url) }
    }

    // MARK: Duplicate / alias

    /// "x copy", "x copy 2" next to each item (APFS clones when possible).
    public func duplicate(_ urls: [URL]) throws -> ([URL], UndoRecord) {
        var made: [URL] = []
        for url in urls {
            let dir = url.deletingLastPathComponent()
            let name = UniqueName.copyName(for: url.lastPathComponent, isFolder: url.isDirectoryOnDisk, taken: UniqueName.takenIn(dir))
            let dest = dir.appendingPathComponent(name)
            do {
                try CopyEngine.copy(url, to: dest, allowClone: true, progress: nil)
            } catch {
                try? fm.removeItem(at: dest) // no half-made "x copy"
                if !made.isEmpty { throw PartialFailure(error: error, undo: .created(made)) }
                throw error
            }
            made.append(dest)
        }
        return (made, .created(made))
    }

    /// Finder aliases ("x alias") next to each item.
    public func makeAlias(_ urls: [URL]) throws -> ([URL], UndoRecord) {
        var made: [URL] = []
        for url in urls {
            let dir = url.deletingLastPathComponent()
            let name = UniqueName.numberedName(for: url.lastPathComponent + " alias", isFolder: true, taken: UniqueName.takenIn(dir))
            let dest = dir.appendingPathComponent(name)
            let data = try url.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
            try URL.writeBookmarkData(data, to: dest)
            made.append(dest)
        }
        return (made, .created(made))
    }

    // MARK: Undo

    /// Reverses `record`; returns the record that redoes it. If it fails partway, throws
    /// `PartialFailure` whose `undo` redoes the part that was reversed.
    public func undo(_ record: UndoRecord) throws -> UndoRecord {
        switch record {
        case .created(let urls):
            return try moveToTrash(urls.filter { FileIdentity.exists($0) })
        case .trashed(let items):
            var restored: [URL] = []
            do {
                for item in items {
                    let dir = item.original.deletingLastPathComponent()
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    var dest = item.original
                    if FileIdentity.exists(dest) {
                        dest = dir.appendingPathComponent(UniqueName.numberedName(for: dest.lastPathComponent, isFolder: dest.hasDirectoryPath, taken: UniqueName.takenIn(dir)))
                    }
                    try fm.moveItem(at: item.inTrash, to: dest)
                    restored.append(dest)
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
                    try fm.moveItem(at: item.to, to: item.from)
                    back.append(MovedItem(from: item.to, to: item.from))
                }
            } catch {
                if !back.isEmpty { throw PartialFailure(error: error, undo: .moved(back.reversed())) }
                throw error
            }
            return .moved(back.reversed())
        case .renamed(let from, let to):
            try fm.moveItem(at: to, to: from)
            return .renamed(from: to, to: from)
        case .group(let records):
            var redo: [UndoRecord] = []
            do {
                for r in records.reversed() { redo.append(try undo(r)) }
            } catch let partial as PartialFailure {
                throw PartialFailure(error: partial.error, undo: .group(redo + [partial.undo]))
            } catch {
                if !redo.isEmpty { throw PartialFailure(error: error, undo: .group(redo)) }
                throw error
            }
            return .group(redo)
        }
    }
}

/// Some items were processed before an error; `undo` covers those.
public struct PartialFailure: Error, LocalizedError {
    public let error: Error
    public let undo: UndoRecord
    public var errorDescription: String? { error.localizedDescription }
}

extension URL {
    /// Real directory test (URL.hasDirectoryPath only reflects a trailing slash).
    public var isDirectoryOnDisk: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// True if `self` is `other` or inside it. `other` itself isn't followed if it's a
    /// symlink: a link is copied or moved as a link, so copying it into its target is fine.
    public func isInside(_ other: URL) -> Bool {
        let a = standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        let o = other.standardizedFileURL
        let bPath = o.path == "/" ? "/" : o.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(o.lastPathComponent).path
        let b = bPath.lowercased()
        return a == b || a.hasPrefix(b.hasSuffix("/") ? b : b + "/")
    }
}
