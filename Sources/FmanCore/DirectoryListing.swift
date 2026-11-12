import Darwin
import Foundation

/// What a listing is sorted by.
public enum SortKey: String, Codable, CaseIterable, Sendable {
    case name, modified, size, kind, created

    /// The direction a fresh sort starts in, as in Finder: names and kinds A→Z,
    /// dates newest first, sizes largest first.
    public var defaultAscending: Bool {
        switch self {
        case .name, .kind: return true
        case .modified, .created, .size: return false
        }
    }
}

public struct FileSort: Equatable, Codable, Sendable {
    public var key: SortKey
    public var ascending: Bool
    public var foldersFirst: Bool

    /// Picking the current key again reverses it; a new key starts in its natural direction.
    public func choosing(_ newKey: SortKey) -> FileSort {
        var s = self
        if newKey == key {
            s.ascending.toggle()
        } else {
            s.key = newKey
            s.ascending = newKey.defaultAscending
        }
        return s
    }

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
    ///
    /// Uses readdir + lstat with kinds cached per extension: asking Launch Services for
    /// every file (kind, type, localized name) costs ~100 µs each, which is a full second
    /// for a 10k-item folder.
    public static func entries(of url: URL, fileManager: FileManager = .default) throws -> [FileItem] {
        let dirPath = url.path
        guard let dir = opendir(dirPath) else {
            let code = errno
            throw NSError(domain: NSCocoaErrorDomain,
                          code: code == EACCES || code == EPERM ? NSFileReadNoPermissionError : (code == ENOENT ? NSFileReadNoSuchFileError : NSFileReadUnknownError),
                          userInfo: [NSFilePathErrorKey: dirPath, NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code))])
        }
        defer { closedir(dir) }
        var parent = stat()
        let parentDevice: dev_t? = lstat(dirPath, &parent) == 0 ? parent.st_dev : nil
        var items: [FileItem] = []
        let base = dirPath.hasSuffix("/") ? dirPath : dirPath + "/"
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            let path = base + name
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            items.append(FileItem(path: path, name: name, stat: st, parentDevice: parentDevice))
        }
        return items
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
        // Bridge names once: localizedStandardCompare on native Swift strings re-bridges
        // both sides on every comparison, which dominated sorting big folders.
        let names = items.map { NSString(string: $0.name) }
        let kinds = order.key == .kind ? items.map { NSString(string: $0.kind) } : []
        func cmp(_ a: NSString, _ b: NSString) -> ComparisonResult { a.localizedStandardCompare(b as String) }
        let indices = items.indices.sorted { i, j in
            let a = items[i], b = items[j]
            if order.foldersFirst, a.isContainer != b.isContainer {
                return a.isContainer
            }
            let result: ComparisonResult
            switch order.key {
            case .name: result = cmp(names[i], names[j])
            case .modified: result = compareOptional(a.modified, b.modified)
            case .size: result = compareOptional(a.size, b.size)
            case .kind: result = cmp(kinds[i], kinds[j])
            case .created: result = compareOptional(a.created, b.created)
            }
            if result == .orderedSame {
                // Stable tie-break on name, always ascending, so equal keys read naturally.
                return cmp(names[i], names[j]) == .orderedAscending
            }
            return order.ascending ? result == .orderedAscending : result == .orderedDescending
        }
        return indices.map { items[$0] }
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
