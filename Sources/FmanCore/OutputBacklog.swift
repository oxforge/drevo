import Foundation

/// Command output that has arrived but is not shown yet. The reader's thread appends, the
/// console takes everything a few times a second, so a command that prints faster than
/// the screen can follow costs the main thread one update per tick, not one per chunk.
/// Bounded: past `limit` only the newest text is kept, and the next `take` says so.
public final class OutputBacklog: @unchecked Sendable {
    /// Consecutive text of one stream.
    public struct Run: Equatable, Sendable {
        public var text: String
        public var isError: Bool

        public init(text: String, isError: Bool) {
            self.text = text
            self.isError = isError
        }
    }

    public struct Batch: Sendable {
        public var runs: [Run] = []
        /// Older output was dropped just before `runs`.
        public var skipped = false

        public var isEmpty: Bool { runs.isEmpty && !skipped }
    }

    /// The most text kept, in UTF-16 units (what a text view counts).
    public let limit: Int

    private let lock = NSLock()
    private var runs: [Run] = []
    /// UTF-16 length of each run, and their sum.
    private var lengths: [Int] = []
    private var length = 0
    private var skipped = false
    private var outStream = ANSIStream()
    private var errStream = ANSIStream()

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Adds a chunk with its escape sequences stripped. True when this made the backlog
    /// non-empty, i.e. when the taker has to be woken.
    @discardableResult
    public func append(_ chunk: String, isError: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let text = isError ? errStream.strip(chunk) : outStream.strip(chunk)
        guard !text.isEmpty else { return false }
        let wasEmpty = runs.isEmpty
        let added = text.utf16.count
        if let last = runs.indices.last, runs[last].isError == isError {
            runs[last].text += text
            lengths[last] += added
        } else {
            runs.append(Run(text: text, isError: isError))
            lengths.append(added)
        }
        length += added
        // Let it overshoot before cutting, so a flood costs one copy per `limit`, not per chunk.
        if length > 2 * limit { trim() }
        return wasEmpty
    }

    /// Everything since the last take, at most `limit` of it.
    public func take() -> Batch {
        lock.lock(); defer { lock.unlock() }
        trim()
        defer { runs = []; lengths = []; length = 0; skipped = false }
        return Batch(runs: runs, skipped: skipped)
    }

    var pendingLength: Int {
        lock.lock(); defer { lock.unlock() }
        return length
    }

    /// Drops text from the front until `limit` is met.
    private func trim() {
        guard length > limit else { return }
        var excess = length - limit
        var whole = 0
        while whole < runs.count - 1, lengths[whole] <= excess {
            excess -= lengths[whole]
            whole += 1
        }
        runs.removeFirst(whole)
        lengths.removeFirst(whole)
        if excess > 0 {
            runs[0].text = Self.dropping(excess, from: runs[0].text)
            lengths[0] = runs[0].text.utf16.count
        }
        length = lengths.reduce(0, +)
        skipped = true
    }

    /// `text` without its first `count` UTF-16 units — or a little more, so that it starts
    /// with a whole character and, when a line break is near, a whole line.
    private static func dropping(_ count: Int, from text: String) -> String {
        let units = text.utf16
        var cut = units.index(units.startIndex, offsetBy: count, limitedBy: units.endIndex) ?? units.endIndex
        while cut < units.endIndex, cut.samePosition(in: text.unicodeScalars) == nil {
            cut = units.index(after: cut)
        }
        let bytes = text.utf8
        let atLineStart = cut == bytes.startIndex || bytes[bytes.index(before: cut)] == 0x0A
        if !atLineStart, let lineBreak = bytes[cut...].prefix(4096).firstIndex(of: 0x0A) {
            cut = bytes.index(after: lineBreak)
        }
        return String(text[cut...])
    }
}
