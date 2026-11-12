import Foundation

/// Finder-compatible naming for copies, duplicates and new folders.
public enum UniqueName {
    /// True for a folder whose whole name is kept when a copy of it is named: "v1.2" →
    /// "v1.2 copy". Packages (.app, .rtfd…) are directories too, but they are named like
    /// files, or the copy stops being a package: "Notes.rtfd" → "Notes copy.rtfd". This is
    /// the value for the `isFolder:` parameters below. A link counts as what it points to.
    public static func isPlainFolder(_ url: URL) -> Bool {
        guard url.isDirectoryOnDisk else { return false }
        var target = url.resolvingSymlinksInPath()
        target.removeAllCachedResourceValues()
        return (try? target.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true
    }

    /// Splits "archive.tar.gz" as Finder does: only the last extension counts, and plain
    /// folders (`isPlainFolder`) and dotfiles without a real extension keep the whole name.
    static func split(_ name: String, isFolder: Bool) -> (base: String, ext: String) {
        if isFolder { return (name, "") }
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        if ext.isEmpty || base.isEmpty { return (name, "") }
        return (base, "." + ext)
    }

    /// "report.txt" → "report copy.txt", then "report copy 2.txt", … (Duplicate, copy into same folder).
    public static func copyName(for name: String, isFolder: Bool, taken: (String) -> Bool) -> String {
        let (base, ext) = split(name, isFolder: isFolder)
        let stem = stripCopySuffix(base) + " copy"
        var candidate = stem + ext
        var n = 2
        while taken(candidate) {
            candidate = "\(stem) \(n)\(ext)"
            n += 1
        }
        return candidate
    }

    /// "report.txt" → "report 2.txt", "report 3.txt", … (Keep Both on conflict).
    public static func numberedName(for name: String, isFolder: Bool, taken: (String) -> Bool) -> String {
        if !taken(name) { return name }
        let (base, ext) = split(name, isFolder: isFolder)
        var n = 2
        var candidate = "\(base) \(n)\(ext)"
        while taken(candidate) {
            n += 1
            candidate = "\(base) \(n)\(ext)"
        }
        return candidate
    }

    /// "untitled folder", "untitled folder 2", …
    public static func newFolderName(taken: (String) -> Bool) -> String {
        numberedName(for: "untitled folder", isFolder: true, taken: taken)
    }

    /// Checks names in a real folder, case-insensitively (APFS default).
    public static func takenIn(_ directory: URL, fileManager: FileManager = .default) -> (String) -> Bool {
        let existing = Set(((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []).map { $0.lowercased() })
        return { existing.contains($0.lowercased()) }
    }

    /// The names in use in the folders an operation writes to, for naming many items.
    /// Each folder is read once and the names made since are added with `add`; `takenIn`
    /// would read the whole folder again for every item. Not thread-safe: one per operation.
    public final class TakenNames {
        private var folders: [FileIdentity: Set<String>] = [:]

        public init() {}

        /// Case-insensitive, like `takenIn`.
        public func contains(_ name: String, in directory: URL) -> Bool {
            if let id = FileIdentity.of(directory, followLinks: true), names(in: directory, id).contains(name.lowercased()) {
                return true
            }
            // The folder can change after it was read (a long copy, another app): never
            // hand out a name that exists now, since a copy onto it would overwrite it.
            return FileIdentity.exists(directory.appendingPathComponent(name, isDirectory: false))
        }

        /// Marks `name` as used in `directory`.
        public func add(_ name: String, in directory: URL) {
            guard let id = FileIdentity.of(directory, followLinks: true) else { return }
            _ = names(in: directory, id)
            folders[id]?.insert(name.lowercased())
        }

        /// The `taken:` argument for `copyName` and `numberedName`.
        public func taken(in directory: URL) -> (String) -> Bool {
            { self.contains($0, in: directory) }
        }

        private func names(in directory: URL, _ id: FileIdentity) -> Set<String> {
            if let known = folders[id] { return known }
            let read = Set(((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).map { $0.lowercased() })
            folders[id] = read
            return read
        }
    }

    /// "a copy" / "a copy 3" → "a", so duplicating a copy gives "a copy 2", not "a copy copy".
    private static func stripCopySuffix(_ base: String) -> String {
        if base.hasSuffix(" copy") { return String(base.dropLast(5)) }
        if let range = base.range(of: #" copy \d+$"#, options: .regularExpression) {
            return String(base[..<range.lowerBound])
        }
        return base
    }
}
