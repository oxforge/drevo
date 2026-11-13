import Foundation

/// keybindings.json as a document the shortcut editor changes: it sets or removes the
/// entries of the commands it edits and keeps every other entry with its value as it was
/// (comments, unknown command ids, keys it can't read). `KeyMap.applyOverrides` stays the
/// only reader of what the entries mean.
public struct KeyBindingsFile: Equatable {
    private var entries: [String: Any]

    public init() { entries = [:] }

    /// An empty or blank file is an empty document; anything else must be a JSON object.
    public init(data: Data) throws {
        guard !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            entries = [:]
            return
        }
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let dict = object as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt, userInfo: [NSLocalizedDescriptionKey: "keybindings.json must be an object of command id → key(s)"])
        }
        entries = dict
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// The command's keys, as a list (an empty list unbinds it).
    public mutating func set(_ keys: [KeyCombo], for id: CommandID) {
        entries[id.rawValue] = keys.map(\.configString)
    }

    public mutating func remove(_ id: CommandID) {
        entries[id.rawValue] = nil
    }

    /// Every entry except comments (keys starting with "_").
    public mutating func removeAllCommands() {
        entries = entries.filter { $0.key.hasPrefix("_") }
    }

    /// Pretty-printed with sorted keys, so "_comment" comes before the command ids.
    public var data: Data {
        var out = (try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        out.append(contentsOf: Array("\n".utf8))
        return out
    }

    public static func == (a: KeyBindingsFile, b: KeyBindingsFile) -> Bool {
        NSDictionary(dictionary: a.entries).isEqual(to: b.entries)
    }
}
