import Foundation

/// A keyboard shortcut, written in config files as e.g. "cmd+shift+n", "f5", "opt+cmd+backspace".
public struct KeyCombo: Hashable, Sendable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public enum NamedKey: String, CaseIterable, Sendable {
        case tab, `return`, space, escape, backspace, forwardDelete = "fn-delete"
        case up, down, left, right, home, end, pageUp = "pageup", pageDown = "pagedown"
        case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20

        public var functionNumber: Int? {
            guard rawValue.hasPrefix("f"), let n = Int(rawValue.dropFirst()) else { return nil }
            return n
        }
    }

    public enum Key: Hashable, Sendable {
        /// A printable character, stored lowercased for letters ("n", "[", "!", ".").
        case character(String)
        case named(NamedKey)
    }

    public var key: Key
    public var modifiers: Modifiers

    public init(_ key: Key, _ modifiers: Modifiers = []) {
        if case .character(let c) = key {
            self.key = .character(c.lowercased())
        } else {
            self.key = key
        }
        self.modifiers = modifiers
    }

    public static func named(_ k: NamedKey, _ modifiers: Modifiers = []) -> KeyCombo { KeyCombo(.named(k), modifiers) }
    public static func char(_ c: String, _ modifiers: Modifiers = []) -> KeyCombo { KeyCombo(.character(c), modifiers) }

    // MARK: Parsing

    public enum ParseError: Error, Equatable { case empty, unknownModifier(String), unknownKey(String) }

    private static let modifierNames: [String: Modifiers] = [
        "cmd": .command, "command": .command, "⌘": .command,
        "shift": .shift, "⇧": .shift,
        "opt": .option, "option": .option, "alt": .option, "⌥": .option,
        "ctrl": .control, "control": .control, "⌃": .control,
    ]

    private static let keyAliases: [String: NamedKey] = [
        "enter": .return, "ret": .return, "esc": .escape, "delete": .backspace, "del": .backspace,
        "forwarddelete": .forwardDelete, "pgup": .pageUp, "pgdn": .pageDown,
    ]

    /// Parses "cmd+shift+n". A literal plus is written "plus" ("cmd+plus").
    public init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ParseError.empty }
        var parts = trimmed.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "cmd++" → last part is the "+" key.
        if trimmed.hasSuffix("++") {
            parts.removeLast(2)
            parts.append("+")
        }
        let keyPart = parts.removeLast()
        var mods: Modifiers = []
        for p in parts {
            guard let m = Self.modifierNames[p.lowercased()] else { throw ParseError.unknownModifier(p) }
            mods.insert(m)
        }
        let lower = keyPart.lowercased()
        if let named = NamedKey(rawValue: lower) ?? Self.keyAliases[lower] {
            self.init(.named(named), mods)
        } else if lower == "plus" {
            self.init(.character("+"), mods)
        } else if keyPart.count == 1 {
            self.init(.character(keyPart), mods)
        } else {
            throw ParseError.unknownKey(keyPart)
        }
    }

    /// Config-file form: "shift+cmd+n".
    public var configString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        switch key {
        case .character(let c): parts.append(c == "+" ? "plus" : c)
        case .named(let k): parts.append(k.rawValue)
        }
        return parts.joined(separator: "+")
    }

    // MARK: Display

    /// Menu-style glyphs in Apple's order: "⌃⌥⇧⌘N", "F5", "⇥", "⌥⌘⌫".
    public var description: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + keyGlyph
    }

    public var keyGlyph: String {
        switch key {
        case .character(let c): return c.uppercased()
        case .named(let k):
            switch k {
            case .tab: return "⇥"
            case .return: return "↩"
            case .space: return "Space"
            case .escape: return "⎋"
            case .backspace: return "⌫"
            case .forwardDelete: return "⌦"
            case .up: return "↑"
            case .down: return "↓"
            case .left: return "←"
            case .right: return "→"
            case .home: return "↖"
            case .end: return "↘"
            case .pageUp: return "⇞"
            case .pageDown: return "⇟"
            default: return k.rawValue.uppercased()
            }
        }
    }

    /// True for keys that type text when pressed without ⌘/⌃ — such bindings must only fire
    /// in file views, never steal keys from text fields.
    public var isPlainTyping: Bool {
        guard !modifiers.contains(.command), !modifiers.contains(.control) else { return false }
        switch key {
        case .character: return true
        case .named(let k): return [.tab, .return, .space, .backspace, .forwardDelete, .left, .right, .up, .down, .home, .end, .pageUp, .pageDown, .escape].contains(k)
        }
    }
}

extension KeyCombo: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        try self.init(parsing: c.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(configString)
    }
}
