import Foundation

/// Which shortcuts may bring Drevo to the front from any app. A global hotkey takes its
/// key away from every other app, so it has to be one nobody types and nothing else uses.
public enum GlobalHotkeyRule {
    /// Why `combo` can't be the global hotkey, or nil if it can. `commandUsing` names the
    /// Drevo command bound to a combo, if any: inside Drevo the hotkey would win over it.
    public static func problem(with combo: KeyCombo, commandUsing: (KeyCombo) -> String? = { _ in nil }) -> String? {
        let isFunctionKey: Bool
        if case .named(let key) = combo.key, key.functionNumber != nil { isFunctionKey = true } else { isFunctionKey = false }
        let hasStrongModifier = combo.modifiers.contains(.command) || combo.modifiers.contains(.control)
        // ⌥ and ⇧ alone type characters (⌥A is å); a bare F-key belongs to the front app.
        guard hasStrongModifier || (isFunctionKey && !combo.modifiers.isEmpty) else {
            return "\(combo) would get in the way of typing. Use a shortcut with ⌘ or ⌃."
        }
        if SystemShortcuts.reserved.contains(combo) {
            return "\(combo) is a macOS shortcut."
        }
        if let command = commandUsing(combo) {
            return "\(combo) is Drevo’s shortcut for “\(command)”."
        }
        return nil
    }
}
