import Foundation

/// Command output that has arrived but is not shown yet. The reader's thread appends, the
/// console takes everything a few times a second, so a command that prints faster than
/// the screen can follow costs the main thread one update per tick, not one per chunk.
/// Bounded: past `limit` only the newest text is kept, and the next `take` says so.
public final class OutputBacklog: @unchecked Sendable {
    /// Consecutive text of one stream in one style.
    public struct Run: Equatable, Sendable {
        public var text: String
        public var isError: Bool
        /// What the command's SGR sequences asked for. Each run carries its whole style,
        /// so dropping the runs before it loses nothing it needs.
        public var style: TextStyle

        public init(text: String, isError: Bool, style: TextStyle = .plain) {
            self.text = text
            self.isError = isError
            self.style = style
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

    /// Adds a chunk: its SGR sequences become the style of the text after them (each
    /// stream has its own, which lasts until the stream changes it), its other escape
    /// sequences are stripped. True when this made the backlog non-empty, i.e. when the
    /// taker has to be woken.
    @discardableResult
    public func append(_ chunk: String, isError: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let spans = isError ? errStream.spans(chunk) : outStream.spans(chunk)
        guard !spans.isEmpty else { return false }
        let wasEmpty = runs.isEmpty
        for span in spans {
            let added = span.text.utf16.count
            if let last = runs.indices.last, runs[last].isError == isError, runs[last].style == span.style {
                runs[last].text += span.text
                lengths[last] += added
            } else {
                runs.append(Run(text: span.text, isError: isError, style: span.style))
                lengths.append(added)
            }
            length += added
        }
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
        // Whether the dropped text ends a line, i.e. the kept text begins one.
        var atLineStart = whole == 0 || runs[whole - 1].text.utf8.last == 0x0A
        runs.removeFirst(whole)
        lengths.removeFirst(whole)
        if excess > 0 {
            let text = runs[0].text
            let cut = Self.characterBoundary(after: excess, in: text)
            atLineStart = text.utf8[..<cut].last == 0x0A
            runs[0].text = String(text[cut...])
            lengths[0] = runs[0].text.utf16.count
        }
        if !atLineStart { dropUnfinishedLine() }
        length = lengths.reduce(0, +)
        skipped = true
    }

    /// The kept text begins in the middle of a line: drops the rest of that line as well,
    /// through all the runs it is coloured in, when its line break is near. Otherwise the
    /// cut stays where it is.
    private func dropUnfinishedLine() {
        var reach = 4096
        for r in runs.indices {
            let text = runs[r].text
            if let lineBreak = text.utf8.prefix(reach).firstIndex(of: 0x0A) {
                runs[r].text = String(text[text.utf8.index(after: lineBreak)...])
                lengths[r] = runs[r].text.utf16.count
                let gone = runs[r].text.isEmpty ? r + 1 : r
                runs.removeFirst(gone)
                lengths.removeFirst(gone)
                return
            }
            reach -= text.utf8.count
            guard reach > 0 else { return }
        }
    }

    /// The position `count` UTF-16 units into `text` — or a little further, so that it
    /// is between two characters.
    private static func characterBoundary(after count: Int, in text: String) -> String.Index {
        let units = text.utf16
        var cut = units.index(units.startIndex, offsetBy: count, limitedBy: units.endIndex) ?? units.endIndex
        while cut < units.endIndex, cut.samePosition(in: text.unicodeScalars) == nil {
            cut = units.index(after: cut)
        }
        return cut
    }
}
