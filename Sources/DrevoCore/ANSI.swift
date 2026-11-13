import Foundation

/// Terminal escape sequences in command output: the ones that style text (SGR) are read,
/// all the others are stripped.
public enum ANSI {
    private static let patterns = [
        #"\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)"#, // OSC … BEL/ST
        #"\x1B\[[0-?]*[ -/]*[@-~]"#,               // CSI
        #"\x1B[@-Z\\-_]"#,                          // other 2-byte escapes
    ]

    static let escape: UInt8 = 0x1B

    /// Whether the UTF-8 text has this byte. Runs for every chunk of output, so it is a
    /// `memchr` rather than a walk through the string.
    static func has(_ byte: UInt8, in s: String) -> Bool {
        s.utf8.withContiguousStorageIfAvailable { memchr($0.baseAddress, Int32(byte), $0.count) != nil }
            ?? s.utf8.contains(byte)
    }

    public static func strip(_ s: String) -> String {
        guard has(escape, in: s) || has(0x0D, in: s) else { return s }
        var out = s
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        // Lone carriage returns (progress bars) would garble a text view; keep line breaks only.
        return out.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "")
    }

    /// `text` cut into spans of one style each: SGR sequences change `style`, everything
    /// else is stripped as `strip` does. `text` must not end inside a sequence.
    static func spans(_ text: String, style: inout TextStyle) -> [StyledText] {
        var spans: [StyledText] = []
        func add(_ visible: String) {
            guard !visible.isEmpty else { return }
            if let last = spans.indices.last, spans[last].style == style {
                spans[last].text += visible
            } else {
                spans.append(StyledText(visible, style))
            }
        }
        guard has(escape, in: text) else {
            add(strip(text))
            return spans
        }
        var text = text
        // Bytes, not characters: this runs for every chunk of coloured output.
        text.withUTF8 { bytes in
            guard let start = bytes.baseAddress else { return }
            let end = bytes.count
            func addText(_ range: Range<Int>) {
                guard !range.isEmpty else { return }
                let from = start + range.lowerBound
                let piece = String(decoding: UnsafeBufferPointer(start: from, count: range.count), as: UTF8.self)
                let isPlain = memchr(from, Int32(escape), range.count) == nil && memchr(from, 0x0D, range.count) == nil
                add(isPlain ? piece : strip(piece))
            }
            var shown = 0 // everything before this is in `spans`
            var i = 0
            while i < end, let found = memchr(start + i, Int32(escape), end - i) {
                let esc = start.distance(to: found.assumingMemoryBound(to: UInt8.self))
                i = esc + 1
                guard i < end, bytes[i] == UInt8(ascii: "[") else { continue }
                // An SGR sequence has plain numbers only. A CSI with a private marker or an
                // intermediate byte can end in `m` too, and means something else.
                var j = i + 1
                while j < end, bytes[j] >= UInt8(ascii: "0"), bytes[j] <= UInt8(ascii: ";") { j += 1 }
                guard j < end, bytes[j] == UInt8(ascii: "m") else { continue }
                addText(shown..<esc)
                style.apply(sgr: UnsafeBufferPointer(start: start + i + 1, count: j - i - 1))
                i = j + 1
                shown = i
            }
            addText(shown..<end)
        }
        return spans
    }

    /// Where the escape sequence that `s` ends in the middle of begins; nil if `s` ends
    /// between sequences.
    static func incompleteTail(of s: String) -> String.Index? {
        let u = s.utf8
        let end = u.endIndex
        var i = u.startIndex
        while let esc = u[i...].firstIndex(of: 0x1B) {
            i = u.index(after: esc)
            guard i < end else { return esc }
            switch u[i] {
            case UInt8(ascii: "["): // CSI: parameters, intermediates, one final byte
                i = u.index(after: i)
                while i < end, (0x30...0x3F).contains(u[i]) { i = u.index(after: i) }
                while i < end, (0x20...0x2F).contains(u[i]) { i = u.index(after: i) }
                guard i < end else { return esc }
            case UInt8(ascii: "]"): // OSC: up to BEL or ESC \ (that ESC is looked at next)
                i = u.index(after: i)
                while i < end, u[i] != 0x07, u[i] != 0x1B { i = u.index(after: i) }
                guard i < end, u[i] == 0x07 || u.index(after: i) < end else { return esc }
            default:
                break
            }
        }
        return nil
    }
}

/// Reads escape sequences in output that arrives in chunks: a sequence cut off by the
/// end of a chunk waits for the next one (as `UTF8Stream` does for bytes). A sequence
/// that never completes is not shown. The style set by SGR sequences carries over from
/// chunk to chunk.
public struct ANSIStream: Sendable {
    private var pending = ""
    /// What the SGR sequences so far add up to: the style of the text that comes next.
    public private(set) var style = TextStyle.plain
    /// Longer than any real sequence; beyond this an unterminated one is passed on as text.
    private static let maxPending = 4096

    public init() {}

    /// The chunk's visible text in the styles its SGR sequences ask for; all other
    /// sequences are stripped.
    public mutating func spans(_ chunk: String) -> [StyledText] {
        guard !pending.isEmpty || ANSI.has(ANSI.escape, in: chunk) else {
            let text = ANSI.strip(chunk)
            return text.isEmpty ? [] : [StyledText(text, style)]
        }
        var text = pending + chunk
        pending = ""
        if let cut = ANSI.incompleteTail(of: text),
           text.utf8.distance(from: cut, to: text.utf8.endIndex) <= Self.maxPending {
            pending = String(text[cut...])
            text = String(text[..<cut])
        }
        return ANSI.spans(text, style: &style)
    }
}
