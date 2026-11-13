import Foundation

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

/// Single-step file operations (fast, synchronous). The ones that can take long run in
/// the background with progress: copy, move and duplicate in `Transfer`, permanent delete
/// in `Deletion`, undo and redo in `Reversal`.
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

    // MARK: Trash

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

    // MARK: Alias

    /// Finder aliases ("x alias") next to each item.
    public func makeAlias(_ urls: [URL]) throws -> ([URL], UndoRecord) {
        var made: [URL] = []
        let names = UniqueName.TakenNames()
        for url in urls {
            let dir = url.deletingLastPathComponent()
            let name = UniqueName.numberedName(for: url.lastPathComponent + " alias", isFolder: true, taken: names.taken(in: dir))
            names.add(name, in: dir)
            let dest = dir.appendingPathComponent(name)
            do {
                let data = try url.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
                try URL.writeBookmarkData(data, to: dest)
            } catch {
                try? fm.removeItem(at: dest) // no half-written alias
                if !made.isEmpty { throw PartialFailure(error: error, undo: .created(made)) }
                throw error
            }
            made.append(dest)
        }
        return (made, .created(made))
    }

    // MARK: Undo

    /// Reverses `record` at once, on the calling thread; returns the record that redoes
    /// it. If it fails partway, throws `PartialFailure` whose `undo` redoes the part that
    /// was reversed. The app runs a `Reversal` in the background instead.
    public func undo(_ record: UndoRecord) throws -> UndoRecord {
        try Reversal(record, trash: trash).reverse()
    }
}
