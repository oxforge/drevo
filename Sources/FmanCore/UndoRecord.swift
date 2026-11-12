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

/// Some items were processed before an error; `undo` covers those.
public struct PartialFailure: Error, LocalizedError {
    public let error: Error
    public let undo: UndoRecord
    public var errorDescription: String? { error.localizedDescription }
}
