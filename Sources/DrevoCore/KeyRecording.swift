import Foundation

/// What the shortcut editor (Settings ▸ Keys) does with a keystroke recorded for a command:
/// the checks run in order, and the result says which commands' keys change.
public enum KeyRecording {
    public struct Context: Sendable {
        /// The keys in effect now.
        public var keyMap: KeyMap
        /// Registry defaults adjusted for the Return-key setting.
        public var defaults: KeyMap
        /// The system-wide "Show Drevo" shortcut, if one is set.
        public var globalHotkey: KeyCombo?
        /// Keys of menu items outside the registry (Close Window…) → their titles.
        public var menuShortcuts: [KeyCombo: String]

        public init(keyMap: KeyMap, defaults: KeyMap, globalHotkey: KeyCombo? = nil, menuShortcuts: [KeyCombo: String] = [:]) {
            self.keyMap = keyMap
            self.defaults = defaults
            self.globalHotkey = globalHotkey
            self.menuShortcuts = menuShortcuts
        }
    }

    /// Where the recorded key goes: in place of one of the command's keys, or after them.
    public enum Slot: Equatable, Sendable {
        case replace(KeyCombo)
        case add
    }

    public enum Outcome: Equatable, Sendable {
        /// The command already has this key.
        case unchanged
        /// The key can't be used; the message says why. Recording goes on.
        case refused(String)
        /// Another command has the key: ask with the message, apply `changes` on "Use Here".
        case taken(String, changes: [CommandID: [KeyCombo]], note: String?)
        case apply([CommandID: [KeyCombo]], note: String?)
    }

    /// `candidates` are the readings of one keystroke, most specific first
    /// (⇧1 is "shift+1" and "!"); the first is the one stored.
    public static func record(_ candidates: [KeyCombo], for id: CommandID, slot: Slot, in context: Context) -> Outcome {
        guard let stored = candidates.first else { return .unchanged }
        if let reserved = candidates.first(where: SystemShortcuts.reserved.contains) {
            return .refused("\(reserved) is a macOS shortcut. Press another, or Esc.")
        }
        if let global = context.globalHotkey, candidates.contains(global) {
            return .refused("\(global) is the shortcut for Show Drevo from any app (Settings ▸ General).")
        }
        if let spec = CommandRegistry.spec(id), spec.isStandardEdit, stored.isPlainTyping {
            return .refused("\(spec.title) also works in text fields, so it needs ⌘ or ⌃.")
        }
        if let path = candidates.first(where: startsPathTyping) {
            return .refused("\(path) starts typing a path in the file list.")
        }
        if let (key, title) = candidates.lazy.compactMap({ c in context.menuShortcuts[c].map { (c, $0) } }).first {
            return .refused("\(key) is the shortcut for \(title).")
        }
        let current = context.keyMap.keys(for: id)
        if candidates.contains(where: current.contains) { return .unchanged }

        var keys = current
        if case .replace(let old) = slot, let i = keys.firstIndex(of: old) {
            keys[i] = stored
        } else {
            keys.append(stored)
        }
        let note = fileListNote(stored)
        if let (other, taken) = owner(of: candidates, besides: id, in: context.keyMap) {
            let title = CommandRegistry.spec(other)?.title ?? other.rawValue
            let remaining = context.keyMap.keys(for: other).filter { !candidates.contains($0) }
            return .taken("\(taken) is \(title)’s shortcut. Use it here instead?", changes: [id: keys, other: remaining], note: note)
        }
        return .apply([id: keys], note: note)
    }

    /// What flipping the Return-key setting does: Return goes first on `target` (Open or
    /// Rename) and comes off every other command, even when they were edited.
    public static func movingReturn(to target: CommandID, in map: KeyMap) -> [CommandID: [KeyCombo]] {
        let ret = KeyCombo.named(.return)
        var changes: [CommandID: [KeyCombo]] = [target: [ret] + map.keys(for: target).filter { $0 != ret }]
        for spec in CommandRegistry.all where spec.id != target && map.keys(for: spec.id).contains(ret) {
            changes[spec.id] = map.keys(for: spec.id).filter { $0 != ret }
        }
        return changes
    }

    /// The first command (registry order) other than `id` bound to one of the readings.
    private static func owner(of candidates: [KeyCombo], besides id: CommandID, in map: KeyMap) -> (CommandID, KeyCombo)? {
        for spec in CommandRegistry.all where spec.id != id {
            if let key = map.keys(for: spec.id).first(where: candidates.contains) { return (spec.id, key) }
        }
        return nil
    }

    /// Plain / and ~ start typing a path in the file list before any command sees them.
    private static func startsPathTyping(_ combo: KeyCombo) -> Bool {
        guard combo.modifiers.subtracting(.shift).isEmpty, case .character(let c) = combo.key else { return false }
        return c == "/" || c == "~"
    }

    /// Plain keys aren't menu shortcuts: they work only through the file list's key handling.
    private static func fileListNote(_ combo: KeyCombo) -> String? {
        guard combo.isPlainTyping else { return nil }
        if case .character = combo.key, combo.modifiers.subtracting(.shift).isEmpty {
            return "Works in the file list only. Typing \(combo.keyGlyph) will no longer start or extend the filter."
        }
        return "Works in the file list only."
    }
}

extension KeyBindingsFile {
    /// Writes each changed command's keys, or removes its entry when they are its default.
    public mutating func apply(_ changes: [CommandID: [KeyCombo]], defaults: KeyMap) {
        for (id, keys) in changes {
            if keys == defaults.keys(for: id) { remove(id) } else { set(keys, for: id) }
        }
    }
}

extension CommandSpec {
    /// The shortcut editor's search: the title or id contains the query, or one of the
    /// keys is the query written either way ("⌘R", "cmd+r", "f2"). An empty query matches.
    public func matches(_ query: String, keys: [KeyCombo]) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        if title.localizedCaseInsensitiveContains(q) || id.rawValue.localizedCaseInsensitiveContains(q) { return true }
        let parsed = try? KeyCombo(parsing: q)
        return keys.contains { $0 == parsed || $0.description.caseInsensitiveCompare(q) == .orderedSame }
    }
}
