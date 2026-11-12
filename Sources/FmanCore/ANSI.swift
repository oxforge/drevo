import Foundation

/// Strips terminal escape sequences from command output for plain display.
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

/// Strips escape sequences from output that arrives in chunks: a sequence cut off by the
/// end of a chunk waits for the next one (as `UTF8Stream` does for bytes). A sequence
/// that never completes is not shown.
public struct ANSIStream: Sendable {
    private var pending = ""
    /// Longer than any real sequence; beyond this an unterminated one is passed on as text.
    private static let maxPending = 4096

    public init() {}

    public mutating func strip(_ chunk: String) -> String {
        guard !pending.isEmpty || ANSI.has(ANSI.escape, in: chunk) else { return ANSI.strip(chunk) }
        let text = pending + chunk
        pending = ""
        guard let cut = ANSI.incompleteTail(of: text),
              text.utf8.distance(from: cut, to: text.utf8.endIndex) <= Self.maxPending
        else { return ANSI.strip(text) }
        pending = String(text[cut...])
        return ANSI.strip(String(text[..<cut]))
    }
}
