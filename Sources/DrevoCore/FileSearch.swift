import Foundation

/// Finds files by name below a folder. Names match by the rules of the pane filter
/// (`NameFilter`: text the name contains, or a `*`/`?` pattern for the whole name).
///
/// The tree is walked folder by folder, which finds everything but takes a while in a
/// big tree. Spotlight, when it has the folder indexed, answers at once but not always
/// completely, so its hits come first and the walk fills in the rest.
public struct FileSearch: Sendable {
    public let root: URL
    public let query: String
    public let showHidden: Bool
    /// More results than this would be no help; the search stops there.
    public var limit = 10_000
    /// How long results pile up before they are handed over, so a UI isn't flooded.
    public var batchInterval: TimeInterval = 0.1
    /// Asks Spotlight for paths of files below `root` whose names match `query`; nil = no
    /// Spotlight (tests). It may return anything: every path is checked again.
    public var spotlight: SpotlightSource? = Spotlight.find
    public typealias SpotlightSource = @Sendable (_ root: URL, _ query: String, _ isCancelled: () -> Bool) -> [String]

    public init(root: URL, query: String, showHidden: Bool) {
        self.root = root
        self.query = query
        self.showHidden = showHidden
    }

    public struct Outcome: Equatable, Sendable {
        public var found = 0
        /// The search stopped at `limit`.
        public var truncated = false
        public var cancelled = false
    }

    /// Runs the search on the calling thread. `onBatch` gets the results as they are
    /// found, each item once.
    @discardableResult
    public func run(isCancelled: () -> Bool = { false }, onBatch: ([FileItem]) -> Void) -> Outcome {
        let filter = NameFilter(query)
        var outcome = Outcome()
        guard !filter.isEmpty else { return outcome }
        let rootPath = root.standardizedFileURL.path
        var seen = Set<String>()
        var batch: [FileItem] = []
        var lastFlush = Date()

        func flush(force: Bool) {
            guard !batch.isEmpty, force || Date().timeIntervalSince(lastFlush) >= batchInterval else { return }
            onBatch(batch)
            batch.removeAll(keepingCapacity: true)
            lastFlush = Date()
        }
        /// False once the limit is reached.
        func add(_ item: FileItem) -> Bool {
            guard seen.insert(item.url.standardizedFileURL.path).inserted else { return true }
            batch.append(item)
            outcome.found += 1
            if outcome.found >= limit {
                outcome.truncated = true
                return false
            }
            flush(force: false)
            return true
        }

        if let spotlight {
            for path in spotlight(root, query, isCancelled) {
                guard Self.isVisible(path, below: rootPath, showHidden: showHidden),
                      filter.matches((path as NSString).lastPathComponent),
                      let item = try? FileItem(url: URL(fileURLWithPath: path)) else { continue }
                if !add(item) { break }
            }
            flush(force: true)
        }

        // Breadth first: what is near the folder being searched shows up first.
        var queue = [root]
        var next = 0
        walk: while next < queue.count, !outcome.truncated {
            if isCancelled() {
                outcome.cancelled = true
                break
            }
            let folder = queue[next]
            next += 1
            guard let entries = try? DirectoryListing.entries(of: folder) else { continue } // unreadable: skip
            for item in entries where showHidden || !item.isHidden {
                if filter.matches(item.name), !add(item) { break walk }
                // Not into packages (an app is one thing) nor through links (loops).
                if item.isContainer, !item.isSymbolicLink { queue.append(item.url) }
            }
        }
        flush(force: true)
        return outcome
    }

    /// True if `path` lies below `rootPath` with no hidden (dot) folder on the way,
    /// unless hidden files are shown.
    static func isVisible(_ path: String, below rootPath: String, showHidden: Bool) -> Bool {
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return false }
        if showHidden { return true }
        return !path.dropFirst(prefix.count).split(separator: "/").contains { $0.hasPrefix(".") }
    }
}

/// Spotlight through `mdfind`.
public enum Spotlight {
    /// The Spotlight query for names matching `query` (as `NameFilter` reads it),
    /// ignoring case and accents.
    static func predicate(for query: String) -> String {
        let text = query.trimmingCharacters(in: .whitespaces)
        let isPattern = text.contains { $0 == "*" || $0 == "?" }
        // In a query string a backslash escapes the next character.
        var escaped = ""
        for c in text {
            if c == "\\" || c == "'" || c == "\"" || (!isPattern && (c == "*" || c == "?")) { escaped.append("\\") }
            escaped.append(c)
        }
        return "kMDItemFSName == '\(isPattern ? escaped : "*\(escaped)*")'cd"
    }

    /// Paths below `root` that Spotlight knows by that name; empty when it can't say.
    public static let find: FileSearch.SpotlightSource = { root, query, isCancelled in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", root.path, predicate(for: query)]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        // The index answers in well under a second; reading to the end is fine, and a
        // cancelled search drops the answer.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard !isCancelled(), process.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}
