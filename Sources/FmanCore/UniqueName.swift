import Foundation

/// Finder-compatible naming for copies, duplicates and new folders.
public enum UniqueName {
    /// Splits "archive.tar.gz" as Finder does: only the last extension counts, and
    /// folders/dotfiles without a real extension keep the whole name.
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

    /// "a copy" / "a copy 3" → "a", so duplicating a copy gives "a copy 2", not "a copy copy".
    private static func stripCopySuffix(_ base: String) -> String {
        if base.hasSuffix(" copy") { return String(base.dropLast(5)) }
        if let range = base.range(of: #" copy \d+$"#, options: .regularExpression) {
            return String(base[..<range.lowerBound])
        }
        return base
    }
}
