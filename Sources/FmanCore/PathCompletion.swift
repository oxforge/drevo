import Foundation

/// Tab completion for the editable path bar.
public enum PathCompletion {
    /// Expands a leading "~" and makes the path absolute relative to `base`.
    public static func expand(_ input: String, relativeTo base: URL? = nil, home: String = NSHomeDirectory()) -> String {
        var s = input.trimmingCharacters(in: .whitespaces)
        if s == "~" { s = home } else if s.hasPrefix("~/") { s = home + s.dropFirst(1) }
        if !s.hasPrefix("/"), let base {
            s = base.path + (base.path.hasSuffix("/") ? "" : "/") + s
        }
        return s
    }

    /// Folder suggestions for `input` (folders only, since the path bar navigates).
    /// Results keep the user's "~" form and end with "/".
    public static func candidates(for input: String, relativeTo base: URL? = nil, showHidden: Bool = false,
                                  home: String = NSHomeDirectory(), fileManager: FileManager = .default) -> [String] {
        let expanded = expand(input, relativeTo: base, home: home)
        let dir: String
        let prefix: String
        if expanded.hasSuffix("/") {
            dir = expanded
            prefix = ""
        } else {
            dir = (expanded as NSString).deletingLastPathComponent
            prefix = (expanded as NSString).lastPathComponent
        }
        guard let names = try? fileManager.contentsOfDirectory(atPath: dir) else { return [] }
        let typedPrefix = input.hasSuffix("/") || input.isEmpty ? input : String(input.dropLast(prefix.count))
        let showDot = showHidden || prefix.hasPrefix(".")
        return names
            .filter { $0.lowercased().hasPrefix(prefix.lowercased()) && (showDot || !$0.hasPrefix(".")) }
            .filter { name in
                var isDir: ObjCBool = false
                let full = (dir as NSString).appendingPathComponent(name)
                return fileManager.fileExists(atPath: full, isDirectory: &isDir) && isDir.boolValue
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { typedPrefix + $0 + "/" }
    }

    /// What Tab inserts: the longest common prefix of the candidates (case-insensitive match,
    /// first candidate's casing), or nil when nothing extends the input.
    public static func complete(_ input: String, candidates: [String]) -> String? {
        guard let first = candidates.first else { return nil }
        if candidates.count == 1 { return first }
        var common = Array(first)
        for c in candidates.dropFirst() {
            let other = Array(c)
            var n = 0
            while n < common.count, n < other.count, common[n].lowercased() == other[n].lowercased() { n += 1 }
            common = Array(common.prefix(n))
        }
        let result = String(common)
        return result.count > input.count ? result : nil
    }
}
