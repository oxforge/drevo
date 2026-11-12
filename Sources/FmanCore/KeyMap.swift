import Foundation

/// The active shortcut table: registry defaults, then user overrides from keybindings.json.
///
/// keybindings.json maps command ids to a key, a list of keys, or null / an empty list (unbind):
/// ```json
/// { "file.rename": "f2", "nav.levelUp": ["left", "h"], "pane.swap": null }
/// ```
public struct KeyMap: Equatable, Sendable {
    public private(set) var bindings: [CommandID: [KeyCombo]]
    /// Commands the user rebound; on a conflict their binding wins over a default.
    public private(set) var overridden: Set<CommandID> = []

    public init(commands: [CommandSpec] = CommandRegistry.all) {
        bindings = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0.defaultKeys) })
    }

    public func keys(for id: CommandID) -> [KeyCombo] { bindings[id] ?? [] }

    /// The command bound to `combo`. On a conflict, a user override beats a default, then
    /// registry order decides; `conflicts` lists every clash.
    public func command(for combo: KeyCombo) -> CommandID? {
        reverse[combo]
    }

    private var reverse: [KeyCombo: CommandID] {
        var map: [KeyCombo: CommandID] = [:]
        let ordered = CommandRegistry.all.filter { overridden.contains($0.id) } + CommandRegistry.all.filter { !overridden.contains($0.id) }
        for spec in ordered {
            for k in bindings[spec.id] ?? [] where map[k] == nil { map[k] = spec.id }
        }
        for (id, keys) in bindings where CommandRegistry.byID[id] == nil {
            for k in keys where map[k] == nil { map[k] = id }
        }
        return map
    }

    /// Shortcuts bound to more than one command.
    public var conflicts: [KeyCombo: [CommandID]] {
        var seen: [KeyCombo: [CommandID]] = [:]
        for (id, keys) in bindings {
            for k in keys { seen[k, default: []].append(id) }
        }
        return seen.filter { $0.value.count > 1 }.mapValues { $0.sorted { $0.rawValue < $1.rawValue } }
    }

    public mutating func set(_ keys: [KeyCombo], for id: CommandID) {
        bindings[id] = keys
        overridden.insert(id)
    }

    /// Finder's behaviour: Return renames; opening stays on ⌘↓.
    public mutating func applyReturnRenames() {
        let ret = KeyCombo.named(.return)
        bindings[.open] = keys(for: .open).filter { $0 != ret }
        if !keys(for: .rename).contains(ret) {
            bindings[.rename] = [ret] + keys(for: .rename)
        }
    }

    // MARK: Overrides file

    public struct OverrideProblem: Equatable, Sendable, CustomStringConvertible {
        public let command: String
        public let message: String
        public var description: String { "\(command): \(message)" }
    }

    /// Applies overrides; returns problems (unknown command, bad key) without failing the rest.
    /// A key that can't be read is skipped; when none of an entry's keys can be read, the
    /// command keeps its current keys.
    @discardableResult
    public mutating func applyOverrides(json data: Data) throws -> [OverrideProblem] {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let dict = object as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt, userInfo: [NSLocalizedDescriptionKey: "keybindings.json must be an object of command id → key(s)"])
        }
        var problems: [OverrideProblem] = []
        for (rawID, value) in dict.sorted(by: { $0.key < $1.key }) {
            if rawID.hasPrefix("_") { continue } // comments: "_comment": "…"
            let id = CommandID(rawID)
            guard CommandRegistry.byID[id] != nil else {
                problems.append(OverrideProblem(command: rawID, message: "unknown command"))
                continue
            }
            let listed: [Any]
            switch value {
            case is NSNull: listed = []
            case let s as String: listed = [s]
            case let a as [Any]: listed = a
            default:
                problems.append(OverrideProblem(command: rawID, message: "expected a string, a list of strings, or null"))
                continue
            }
            var combos: [KeyCombo] = []
            for entry in listed {
                guard let s = entry as? String else {
                    problems.append(OverrideProblem(command: rawID, message: "keys in a list must be strings"))
                    continue
                }
                do { combos.append(try KeyCombo(parsing: s)) } catch {
                    problems.append(OverrideProblem(command: rawID, message: "can't read key \"\(s)\""))
                }
            }
            // Keys were listed but none could be read: a typo, not a request to unbind.
            // The command keeps the keys it has; only null or an empty list unbinds.
            if combos.isEmpty && !listed.isEmpty { continue }
            bindings[id] = combos
            overridden.insert(id)
        }
        return problems
    }

    /// The starter keybindings.json: no overrides, just a pointer to the defaults.
    public static let starterJSON = """
    {
      "_comment": "Override shortcuts here; keybindings.defaults.json lists every command id with its default keys. A value is one key ('f2'), a list (['f2', 'cmd+r']) or null to unbind. Keys: cmd, shift, opt, ctrl + a letter, symbol, f1-f20, return, tab, space, escape, backspace, up, down, left, right. Changes apply when you switch back to fman.",
      "_example_vim_style": { "nav.levelUp": ["left", "h"], "nav.levelDown": ["right", "l"] }
    }

    """

    /// Every command with its current keys (the reference file next to keybindings.json).
    public func templateJSON() -> String {
        var lines = ["{"]
        let specs = CommandRegistry.all
        for (i, spec) in specs.enumerated() {
            let keys = self.keys(for: spec.id).map { "\"\($0.configString)\"" }.joined(separator: ", ")
            let comma = i == specs.count - 1 ? "" : ","
            lines.append("  \"\(spec.id.rawValue)\": [\(keys)]\(comma)")
        }
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }
}
