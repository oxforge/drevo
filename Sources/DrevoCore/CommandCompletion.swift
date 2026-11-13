import Foundation

/// Tab completion for the command line: file and folder names for the word before the cursor.
public enum CommandCompletion {
    public struct Choice: Equatable, Sendable {
        /// The item's name, for a menu.
        public let title: String
        /// The escaped text that replaces the word.
        public let replacement: String
    }

    public struct Result: Equatable, Sendable {
        /// The word before the cursor, as a UTF-16 range of the line.
        public let range: NSRange
        /// What Tab inserts in place of `range`; nil when nothing extends the word.
        public let replacement: String?
        /// Every match, for a menu when `replacement` is nil.
        public let choices: [Choice]
    }

    /// Completes the word that ends at `cursor` (a UTF-16 offset). Names match without
    /// regard to case; hidden items only when the word's name part starts with a dot.
    public static func complete(line: String, cursor: Int, relativeTo base: URL,
                                home: String = NSHomeDirectory(), fileManager: FileManager = .default) -> Result {
        let word = wordBefore(cursor, in: line)
        let typedDir: String
        let prefix: String
        if let slash = word.text.lastIndex(of: "/") {
            typedDir = String(word.text[...slash])
            prefix = String(word.text[word.text.index(after: slash)...])
        } else {
            typedDir = ""
            prefix = word.text
        }
        let dir = directory(typedDir, base: base, home: home)
        let names = ((try? fileManager.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.lowercased().hasPrefix(prefix.lowercased()) && (prefix.hasPrefix(".") || !$0.hasPrefix(".")) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let matches = names.map { name -> (name: String, text: String, isFolder: Bool) in
            var isDir: ObjCBool = false
            fileManager.fileExists(atPath: (dir as NSString).appendingPathComponent(name), isDirectory: &isDir)
            return (name, typedDir + name + (isDir.boolValue ? "/" : ""), isDir.boolValue)
        }
        let choices = matches.map { Choice(title: $0.name, replacement: escape($0.text) + ($0.isFolder ? "" : " ")) }
        var replacement: String?
        if choices.count == 1 {
            replacement = choices[0].replacement
        } else if let common = PathCompletion.complete(word.text, candidates: matches.map(\.text)), common.count > word.text.count {
            replacement = escape(common)
        }
        return Result(range: word.range, replacement: replacement, choices: choices)
    }

    /// The folder a typed "dir/" part means: "~/" is Home, a relative one is below `base`.
    private static func directory(_ typed: String, base: URL, home: String) -> String {
        if typed.hasPrefix("/") { return typed }
        if typed.hasPrefix("~/") { return home + typed.dropFirst(1) }
        return base.path + (base.path.hasSuffix("/") ? "" : "/") + typed
    }

    /// The shell word that ends at `cursor`, with quotes and backslashes resolved.
    static func wordBefore(_ cursor: Int, in line: String) -> (range: NSRange, text: String) {
        let units = Array(line.utf16.prefix(max(0, cursor)))
        var start = 0
        var text: [unichar] = []
        var quote: unichar?
        var escaped = false
        let single = unichar(39), double = unichar(34), backslash = unichar(92)
        let breaks = Set(" \t;|&<>(".utf16)
        for (i, u) in units.enumerated() {
            if escaped {
                text.append(u)
                escaped = false
            } else if let q = quote {
                if u == q { quote = nil } else if u == backslash, q == double { escaped = true } else { text.append(u) }
            } else if u == backslash {
                escaped = true
            } else if u == single || u == double {
                quote = u
            } else if breaks.contains(u) {
                start = i + 1
                text = []
            } else {
                text.append(u)
            }
        }
        return (NSRange(location: start, length: units.count - start), String(utf16CodeUnits: text, count: text.count))
    }

    private static let special = Set(" \t!\"#$&'()*;<>?[\\]^`{|}")

    /// Backslash-escapes what the shell would read as syntax; a leading "~/" stays as typed.
    static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            if special.contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }
}
