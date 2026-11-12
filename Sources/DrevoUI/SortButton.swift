import AppKit
import DrevoCore

/// The sort control in a pane header: shows the current order ("Kind ↑") and offers
/// every sort key plus the direction.
@MainActor
final class SortButton: NSPopUpButton {
    var onChoose: ((SortKey) -> Void)?
    var onReverse: (() -> Void)?
    private(set) var current = FileSort()

    static let keys: [(SortKey, String)] = [
        (.name, "Name"), (.kind, "Kind"), (.modified, "Date Modified"), (.created, "Date Created"), (.size, "Size"),
    ]

    static func shortTitle(_ key: SortKey) -> String {
        switch key {
        case .name: return "Name"
        case .kind: return "Kind"
        case .modified: return "Modified"
        case .created: return "Created"
        case .size: return "Size"
        }
    }

    init() {
        super.init(frame: .zero, pullsDown: true)
        isBordered = false
        controlSize = .small
        font = .systemFont(ofSize: 11)
        (cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        contentTintColor = .secondaryLabelColor
        toolTip = Self.toolTip(keyMap: KeyMap())
        update(current)
    }

    /// The commands that choose each sort key, in the menu's order.
    private static let commands: [SortKey: CommandID] = [
        .name: .sortByName, .kind: .sortByKind, .modified: .sortByModified, .created: .sortByCreated, .size: .sortBySize,
    ]

    /// "Sort order" and the shortcut of every sort key that has one in `keyMap`.
    static func toolTip(keyMap: KeyMap) -> String {
        let shortcuts = keys.compactMap { key, title in
            commands[key].flatMap { keyMap.keys(for: $0).first }.map { "\($0) \(title)" }
        }
        return shortcuts.isEmpty ? "Sort order" : "Sort order (\(shortcuts.joined(separator: ", ")))"
    }

    /// Shows the shortcuts as `keyMap` binds them; called again when the bindings change.
    func showShortcuts(_ keyMap: KeyMap) {
        toolTip = Self.toolTip(keyMap: keyMap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var titleText: String { (itemArray.first?.title) ?? "" }

    func update(_ sort: FileSort) {
        current = sort
        removeAllItems()
        // A pull-down's first item is its face.
        addItem(withTitle: "\(Self.shortTitle(sort.key)) \(sort.ascending ? "↑" : "↓")")
        let face = itemArray[0]
        face.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "Sort")
        face.image?.isTemplate = true
        for item in Self.menuItems(for: sort, target: self, choose: #selector(chooseKey(_:)), reverse: #selector(reverse(_:))) {
            menu?.addItem(item)
        }
    }

    /// Menu entries for a sort (also used in the background context menu).
    static func menuItems(for sort: FileSort, target: AnyObject, choose: Selector, reverse: Selector) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for (key, title) in keys {
            let item = NSMenuItem(title: title, action: choose, keyEquivalent: "")
            item.target = target
            item.representedObject = key.rawValue
            item.state = sort.key == key ? .on : .off
            items.append(item)
        }
        items.append(.separator())
        let asc = sort.key == .name || sort.key == .kind ? ("A to Z", "Z to A")
            : sort.key == .size ? ("Smallest First", "Largest First") : ("Oldest First", "Newest First")
        for (title, ascending) in [(asc.0, true), (asc.1, false)] {
            let item = NSMenuItem(title: title, action: reverse, keyEquivalent: "")
            item.target = target
            item.state = sort.ascending == ascending ? .on : .off
            item.representedObject = ascending
            items.append(item)
        }
        return items
    }

    @objc private func chooseKey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = SortKey(rawValue: raw), key != current.key else { return }
        onChoose?(key)
    }

    @objc private func reverse(_ sender: NSMenuItem) {
        guard let ascending = sender.representedObject as? Bool, ascending != current.ascending else { return }
        onReverse?()
    }
}
