import AppKit
import DrevoCore

extension KeyCombo.Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var m: KeyCombo.Modifiers = []
        let f = flags.intersection(.deviceIndependentFlagsMask)
        if f.contains(.command) { m.insert(.command) }
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.option) { m.insert(.option) }
        if f.contains(.control) { m.insert(.control) }
        self = m
    }

    var eventFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if contains(.command) { f.insert(.command) }
        if contains(.shift) { f.insert(.shift) }
        if contains(.option) { f.insert(.option) }
        if contains(.control) { f.insert(.control) }
        return f
    }
}

extension KeyCombo {
    private static let namedByKeyCode: [UInt16: NamedKey] = [
        48: .tab, 36: .return, 76: .return, 49: .space, 53: .escape, 51: .backspace, 117: .forwardDelete,
        126: .up, 125: .down, 123: .left, 124: .right, 115: .home, 119: .end, 116: .pageUp, 121: .pageDown,
        122: .f1, 120: .f2, 99: .f3, 118: .f4, 96: .f5, 97: .f6, 98: .f7, 100: .f8, 101: .f9, 109: .f10,
        103: .f11, 111: .f12, 105: .f13, 107: .f14, 113: .f15, 106: .f16, 64: .f17, 79: .f18, 80: .f19, 90: .f20,
    ]

    /// The ways an event can be written as a combo, most specific first:
    /// ⇧⌘. reads as "shift+cmd+." and ⇧1 also as "!".
    static func candidates(for event: NSEvent) -> [KeyCombo] {
        guard event.type == .keyDown else { return [] }
        let mods = Modifiers(event.modifierFlags)
        if let named = namedByKeyCode[event.keyCode] {
            return [KeyCombo(.named(named), mods)]
        }
        var result: [KeyCombo] = []
        if let base = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers, base.count == 1 {
            result.append(KeyCombo(.character(base), mods))
        }
        if mods.contains(.shift), let shifted = event.characters(byApplyingModifiers: .shift), shifted.count == 1,
           shifted.lowercased() == shifted { // a symbol, not an uppercase letter
            var m = mods
            m.remove(.shift)
            result.append(KeyCombo(.character(shifted), m))
        }
        return result
    }

    /// AppKit menu key equivalent; nil for keys that must not live in menus (plain typing keys).
    var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        if isPlainTyping { return nil }
        let key: String
        switch self.key {
        case .character(let c): key = c
        case .named(let k):
            switch k {
            case .backspace: key = "\u{8}"
            case .forwardDelete: key = String(UnicodeScalar(NSDeleteFunctionKey)!)
            case .up: key = String(UnicodeScalar(NSUpArrowFunctionKey)!)
            case .down: key = String(UnicodeScalar(NSDownArrowFunctionKey)!)
            case .left: key = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
            case .right: key = String(UnicodeScalar(NSRightArrowFunctionKey)!)
            case .home: key = String(UnicodeScalar(NSHomeFunctionKey)!)
            case .end: key = String(UnicodeScalar(NSEndFunctionKey)!)
            case .pageUp: key = String(UnicodeScalar(NSPageUpFunctionKey)!)
            case .pageDown: key = String(UnicodeScalar(NSPageDownFunctionKey)!)
            case .tab: key = "\t"
            case .return: key = "\r"
            case .space: key = " "
            case .escape: key = "\u{1b}"
            default:
                guard let n = k.functionNumber else { return nil }
                key = String(UnicodeScalar(NSF1FunctionKey + n - 1)!)
            }
        }
        return (key, modifiers.eventFlags)
    }
}

extension KeyMap {
    /// The command an event triggers, trying each way of reading the event.
    func command(for event: NSEvent) -> CommandID? {
        for combo in KeyCombo.candidates(for: event) {
            if let id = command(for: combo) { return id }
        }
        return nil
    }

    /// First binding that can be shown and fired by a menu item.
    func menuKey(for id: CommandID) -> KeyCombo? {
        keys(for: id).first { $0.menuKeyEquivalent != nil }
    }

    /// Default keymap adjusted for preferences, plus ~/Library/Application Support/drevo/keybindings.json.
    @MainActor
    static func load(preferences: Preferences, overridesURL: URL? = KeyMap.userOverridesURL) -> (KeyMap, [String]) {
        var map = KeyMap()
        if preferences.returnRenames { map.applyReturnRenames() }
        var problems: [String] = []
        if let url = overridesURL, let data = try? Data(contentsOf: url) {
            do {
                problems = try map.applyOverrides(json: data).map(\.description)
            } catch {
                problems = ["keybindings.json: \(error.localizedDescription)"]
            }
        }
        return (map, problems)
    }

    static var userOverridesURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("drevo/keybindings.json")
    }
}
