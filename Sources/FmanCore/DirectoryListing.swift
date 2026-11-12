import Foundation

/// What a listing is sorted by.
public enum SortKey: String, Codable, CaseIterable, Sendable {
    case name, modified, size, kind
}

public struct FileSort: Equatable, Codable, Sendable {
    public var key: SortKey
    public var ascending: Bool
    public var foldersFirst: Bool

    public init(key: SortKey = .name, ascending: Bool = true, foldersFirst: Bool = true) {
        self.key = key
        self.ascending = ascending
        self.foldersFirst = foldersFirst
    }
}

public struct ListingOptions: Equatable, Sendable {
    public var showHidden: Bool
    public var sort: FileSort
    /// Case-insensitive substring filter on the name; empty = no filter.
    public var filter: String

    public init(showHidden: Bool = false, sort: FileSort = FileSort(), filter: String = "") {
        self.showHidden = showHidden
        self.sort = sort
        self.filter = filter
    }
}

/// Loads, filters and sorts folder contents.
public enum DirectoryListing {
    /// All entries of `url`, unfiltered and unsorted.
    public static func entries(of url: URL, fileManager: FileManager = .default) throws -> [FileItem] {
        let urls = try fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: FileItem.resourceKeys, options: [])
        return urls.compactMap { try? FileItem(url: $0) }
    }

    public static func load(_ url: URL, options: ListingOptions, fileManager: FileManager = .default) throws -> [FileItem] {
        apply(options, to: try entries(of: url, fileManager: fileManager))
    }

    public static func apply(_ options: ListingOptions, to items: [FileItem]) -> [FileItem] {
        var result = options.showHidden ? items : items.filter { !$0.isHidden }
        let needle = options.filter.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            result = result.filter { $0.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        return sorted(result, by: options.sort)
    }

    public static func sorted(_ items: [FileItem], by order: FileSort) -> [FileItem] {
        items.sorted { a, b in
            if order.foldersFirst, a.isContainer != b.isContainer {
                return a.isContainer
            }
            let result = compare(a, b, key: order.key)
            if result == .orderedSame {
                // Stable tie-break on name, always ascending, so equal keys read naturally.
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return order.ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private static func compare(_ a: FileItem, _ b: FileItem, key: SortKey) -> ComparisonResult {
        switch key {
        case .name:
            return a.name.localizedStandardCompare(b.name)
        case .modified:
            return compareOptional(a.modified, b.modified)
        case .size:
            return compareOptional(a.size, b.size)
        case .kind:
            return a.kind.localizedStandardCompare(b.kind)
        }
    }

    /// nil sorts before any value (folders have no size).
    private static func compareOptional<T: Comparable>(_ a: T?, _ b: T?) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        case let (x?, y?): return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        }
    }
}
