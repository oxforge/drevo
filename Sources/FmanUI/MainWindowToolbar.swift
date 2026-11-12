import AppKit
import FmanCore

/// The window's toolbar: which items it offers, how each is built and what it runs
/// (the `NSToolbarDelegate` methods).
extension MainWindowController {
    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .fmanNavigation, .flexibleSpace, .fmanViewMode, .fmanHidden, .fmanNewFolder, .fmanTerminal]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .fmanPalette, .fmanSwap]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .fmanNavigation:
            let group = NSToolbarItemGroup(itemIdentifier: id,
                                           images: [symbol("chevron.left"), symbol("chevron.right")],
                                           selectionMode: .momentary, labels: ["Back", "Forward"],
                                           target: self, action: #selector(navigationClicked(_:)))
            group.label = "Back/Forward"
            group.isNavigational = true
            return group
        case .fmanViewMode:
            let group = NSToolbarItemGroup(itemIdentifier: id,
                                           images: [symbol("list.bullet"), symbol("rectangle.split.3x1")],
                                           selectionMode: .selectOne, labels: ["List", "Columns"],
                                           target: self, action: #selector(viewModeClicked(_:)))
            group.label = "View"
            group.selectedIndex = paneGroup.activePane.viewMode == .list ? 0 : 1
            return group
        case .fmanHidden:
            return button(id, "eye.slash", "Hidden Files", .toggleHidden)
        case .fmanNewFolder:
            return button(id, "folder.badge.plus", "New Folder", .newFolder)
        case .fmanTerminal:
            return button(id, "terminal", "Open in Terminal", .openTerminal)
        case .fmanPalette:
            return button(id, "command", "Commands", .commandPalette)
        case .fmanSwap:
            return button(id, "arrow.left.arrow.right", "Swap Panes", .swapPanes)
        default:
            return nil
        }
    }

    private func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: name)!
    }

    private func button(_ id: NSToolbarItem.Identifier, _ symbolName: String, _ label: String, _ command: CommandID) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = symbol(symbolName)
        item.label = label
        item.paletteLabel = label
        let keys = env.keyMap.keys(for: command).map(\.description).joined(separator: " or ")
        item.toolTip = keys.isEmpty ? label : "\(label) (\(keys))"
        item.target = self
        item.action = #selector(toolbarCommand(_:))
        item.isBordered = true
        commandForToolbarItem[id] = command
        return item
    }

    @objc private func toolbarCommand(_ sender: NSToolbarItem) {
        if let id = commandForToolbarItem[sender.itemIdentifier] { perform(id) }
    }

    @objc private func navigationClicked(_ sender: NSToolbarItemGroup) {
        perform(sender.selectedIndex == 0 ? .back : .forward)
    }

    @objc private func viewModeClicked(_ sender: NSToolbarItemGroup) {
        perform(sender.selectedIndex == 0 ? .listView : .columnsView)
        paneGroup.activePane.focus()
    }
}

extension NSToolbarItem.Identifier {
    static let fmanNavigation = NSToolbarItem.Identifier("fman.navigation")
    static let fmanViewMode = NSToolbarItem.Identifier("fman.viewMode")
    static let fmanHidden = NSToolbarItem.Identifier("fman.hidden")
    static let fmanNewFolder = NSToolbarItem.Identifier("fman.newFolder")
    static let fmanTerminal = NSToolbarItem.Identifier("fman.terminal")
    static let fmanPalette = NSToolbarItem.Identifier("fman.palette")
    static let fmanSwap = NSToolbarItem.Identifier("fman.swap")
}
