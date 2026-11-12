import Foundation

public enum TransferKind: String, Sendable {
    case copy, move
}

/// Finder's drag & drop rule: same volume moves, another volume copies;
/// ⌥ forces copy, ⌘ forces move.
public enum DropPolicy {
    public static func kind(sourceVolume: AnyHashable?, destinationVolume: AnyHashable?,
                            optionKey: Bool, commandKey: Bool) -> TransferKind {
        if optionKey { return .copy }
        if commandKey { return .move }
        guard let s = sourceVolume, let d = destinationVolume else { return .copy }
        return s == d ? .move : .copy
    }

    public static func volumeIdentifier(of url: URL) -> AnyHashable? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier.map { AnyHashable($0 as! NSObject) }
    }

    /// All sources must share the destination's volume for a plain drag to move them.
    public static func kind(sources: [URL], destination: URL, optionKey: Bool, commandKey: Bool) -> TransferKind {
        let dest = volumeIdentifier(of: destination)
        let sameVolume = sources.allSatisfy { volumeIdentifier(of: $0) == dest }
        if optionKey { return .copy }
        if commandKey { return .move }
        return sameVolume && dest != nil ? .move : .copy
    }
}
