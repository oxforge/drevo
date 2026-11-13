import Foundation

/// How a piece of command output asked to be shown: what its SGR sequences (ESC [ … m)
/// have set so far. A plain value, so it is built off the main thread and compared
/// cheaply; the console maps it to colours and fonts.
public struct TextStyle: Hashable, Sendable {
    public enum Color: Hashable, Sendable {
        /// One of the 16 named colours: 0–7 black, red, green, yellow, blue, magenta,
        /// cyan, white; 8–15 their bright variants. What they look like is the console's
        /// choice, since it depends on the appearance.
        case palette(UInt8)
        /// An exact colour: truecolor, or 16–255 of the 256-colour table.
        case rgb(UInt8, UInt8, UInt8)

        /// Entry `index` of the 256-colour table: the palette, a 6×6×6 cube, 24 greys.
        public static func indexed(_ index: UInt8) -> Color {
            switch index {
            case 0..<16:
                return .palette(index)
            case 16..<232:
                let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
                let n = Int(index) - 16
                return .rgb(levels[n / 36], levels[n / 6 % 6], levels[n % 6])
            default:
                let grey = UInt8(8 + 10 * (Int(index) - 232))
                return .rgb(grey, grey, grey)
            }
        }
    }

    /// nil = the console's own colour for that stream.
    public var foreground: Color?
    public var background: Color?
    public var bold: Bool
    public var dim: Bool
    public var italic: Bool
    public var underline: Bool
    /// Foreground and background swapped.
    public var inverse: Bool

    public init(foreground: Color? = nil, background: Color? = nil, bold: Bool = false, dim: Bool = false,
                italic: Bool = false, underline: Bool = false, inverse: Bool = false) {
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.dim = dim
        self.italic = italic
        self.underline = underline
        self.inverse = inverse
    }

    public static let plain = TextStyle()

    public var isPlain: Bool { self == .plain }

    /// Applies the parameters of one SGR sequence: the bytes between `ESC [` and `m`,
    /// digits separated by `;` (and `:` inside one parameter). Parameters that are not
    /// rendered (blink, strike-through, …) are skipped.
    public mutating func apply<Bytes: Sequence>(sgr bytes: Bytes) where Bytes.Element == UInt8 {
        let bytes = Array(bytes)
        guard bytes.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: ";")).contains($0) }) else {
            return // not an SGR sequence after all
        }
        bytes.withUnsafeBufferPointer { apply(sgr: $0) }
    }

    /// The same for bytes already known to be digits, `;` and `:`. Not generic and
    /// without a copy: this runs for every sequence in the output.
    mutating func apply(sgr bytes: UnsafeBufferPointer<UInt8>) {
        var parameters = Parameters(bytes: bytes)
        while let code = parameters.next() {
            switch code {
            case 0: self = .plain
            case 1: bold = true
            case 2: dim = true
            case 3: italic = true
            case 4: underline = parameters.parts.first != 0 // 4:0 = none, 4:3 = curly, …
            case 7: inverse = true
            case 21: underline = true // doubly underlined
            case 22: bold = false; dim = false
            case 23: italic = false
            case 24: underline = false
            case 27: inverse = false
            case 30...37: foreground = .palette(UInt8(code - 30))
            case 39: foreground = nil
            case 40...47: background = .palette(UInt8(code - 40))
            case 49: background = nil
            case 90...97: foreground = .palette(UInt8(code - 90 + 8))
            case 100...107: background = .palette(UInt8(code - 100 + 8))
            case 38, 48:
                var kind: [Int] // 5, n or 2, r, g, b
                if parameters.parts.isEmpty { // 38;5;n or 38;2;r;g;b: in the parameters that follow
                    kind = [parameters.next() ?? 0]
                    for _ in 0..<(kind[0] == 5 ? 1 : kind[0] == 2 ? 3 : 0) {
                        if let value = parameters.next() { kind.append(value) }
                    }
                } else { // 38:5:n, 38:2:r:g:b or 38:2:<colour space>:r:g:b
                    kind = parameters.parts
                    if kind.count >= 5 { kind.removeSubrange(1..<(kind.count - 3)) }
                }
                func component(_ i: Int) -> UInt8 { UInt8(min(kind[i], 255)) }
                let color: Color
                switch (kind[0], kind.count) {
                case (5, 2...): color = .indexed(component(1))
                case (2, 4...): color = .rgb(component(1), component(2), component(3))
                case _ where parameters.parts.isEmpty:
                    return // cut short or of an unknown kind: where the next parameter starts is unknown
                default: continue
                }
                if code == 38 { foreground = color } else { background = color }
            default:
                break
            }
        }
    }

    /// Reads the numbers of an SGR sequence one by one. An empty one counts as 0.
    private struct Parameters {
        let bytes: UnsafeBufferPointer<UInt8>
        private var position = 0
        /// What followed the number last read inside its parameter, after colons.
        private(set) var parts: [Int] = []

        init(bytes: UnsafeBufferPointer<UInt8>) {
            self.bytes = bytes
        }

        mutating func next() -> Int? {
            guard position <= bytes.count else { return nil }
            if !parts.isEmpty { parts.removeAll(keepingCapacity: true) }
            var first: Int?
            var value = 0
            while position < bytes.count, bytes[position] != UInt8(ascii: ";") {
                if bytes[position] == UInt8(ascii: ":") {
                    if first == nil { first = value } else { parts.append(value) }
                    value = 0
                } else {
                    value = min(value * 10 + Int(bytes[position] - UInt8(ascii: "0")), 9999)
                }
                position += 1
            }
            position += 1 // past the semicolon, or past the end after the last one
            guard let first else { return value }
            parts.append(value)
            return first
        }
    }
}

/// Text that is all in one style.
public struct StyledText: Equatable, Sendable {
    public var text: String
    public var style: TextStyle

    public init(_ text: String, _ style: TextStyle = .plain) {
        self.text = text
        self.style = style
    }
}
