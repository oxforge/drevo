import AppKit
import DrevoCore

/// Builds the menu bar from the command registry so menus always show the live keymap.
@MainActor
enum MainMenu {
    nonisolated static let commandAction = #selector(MainWindowController.performCommand(_:))

    /// Keys of the menu items `build` adds outside the registry, by title. The shortcut
    /// editor refuses them; a test keeps this in step with the menu.
    nonisolated static let fixedShortcuts: [KeyCombo: String] = [
        "cmd+,": "Settings…", "cmd+h": "Hide Drevo", "opt+cmd+h": "Hide Others", "cmd+q": "Quit Drevo",
        "shift+cmd+w": "Close Window", "ctrl+cmd+f": "Enter Full Screen", "cmd+m": "Minimize",
    ].reduce(into: [:]) { $0[try! KeyCombo(parsing: $1.key)] = $1.value }

    static func build(keyMap: KeyMap) -> NSMenu {
        let main = NSMenu()

        let app = submenu(main, "Drevo")
        app.addItem(withTitle: "About Drevo", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(withTitle: "Check for Updates…", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        let services = NSMenu()
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Drevo", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Drevo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(main, "File")
        add(file, [.newWindow, .newTab], keyMap)
        file.addItem(.separator())
        add(file, [.open, .quickLook, .edit, .showPackageContents, .revealInFinder], keyMap)
        file.addItem(.separator())
        add(file, [.newFolder, .newFile, .rename, .duplicate, .makeAlias], keyMap)
        file.addItem(.separator())
        add(file, [.copyToOtherPane, .moveToOtherPane], keyMap)
        file.addItem(.separator())
        add(file, [.getInfo, .copyPath, .addToSidebar], keyMap)
        file.addItem(.separator())
        add(file, [.moveToTrash, .deleteImmediately], keyMap)
        file.addItem(.separator())
        // ⌘W closes a tab, and the window with the pane's last one; ⇧⌘W always the window.
        add(file, [.closeTab], keyMap)
        let closeWindow = file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]

        let edit = submenu(main, "Edit")
        add(edit, [.undo, .redo], keyMap)
        edit.addItem(.separator())
        add(edit, [.cut, .copy, .paste, .pasteMove, .selectAll], keyMap)
        edit.addItem(.separator())
        add(edit, [.filter, .search], keyMap)

        let view = submenu(main, "View")
        add(view, [.listView, .columnsView], keyMap)
        let sortBy = view.addItem(withTitle: "Sort By", action: nil, keyEquivalent: "")
        let sortMenu = NSMenu(title: "Sort By")
        add(sortMenu, [.sortByName, .sortByKind, .sortByModified, .sortByCreated, .sortBySize], keyMap)
        sortMenu.addItem(.separator())
        add(sortMenu, [.reverseSort], keyMap)
        sortBy.submenu = sortMenu
        view.addItem(.separator())
        add(view, [.toggleHidden], keyMap)
        add(view, [.biggerRows, .smallerRows], keyMap)
        view.addItem(.separator())
        add(view, [.toggleSidebar, .toggleStatusBar, .toggleCommandLine, .toggleKeyHints], keyMap)
        view.addItem(.separator())
        add(view, [.commandPalette], keyMap)
        view.addItem(.separator())
        let fullScreen = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]

        let go = submenu(main, "Go")
        add(go, [.back, .forward, .enclosingFolder], keyMap)
        go.addItem(.separator())
        add(go, [.goHome, .goDesktop, .goDocuments, .goDownloads, .goApplications, .goUtilities, .goVolumes], keyMap)
        go.addItem(.separator())
        add(go, [.goToPath], keyMap)

        let panes = submenu(main, "Panes")
        add(panes, [.nextPane, .previousPane, .swapPanes, .openInOtherPane], keyMap)
        panes.addItem(.separator())
        add(panes, [.addPane, .removePane], keyMap)
        panes.addItem(.separator())
        add(panes, [.equalizePanes], keyMap)

        let shell = submenu(main, "Shell")
        add(shell, [.openTerminal, .runCommand, .runInTerminal], keyMap)
        shell.addItem(.separator())
        add(shell, [.toggleConsole, .stopCommand], keyMap)

        let window = submenu(main, "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        add(window, [.nextTab, .previousTab], keyMap)
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        let help = submenu(main, "Help")
        help.addItem(withTitle: "Keyboard Shortcuts", action: #selector(AppDelegate.showShortcuts(_:)), keyEquivalent: "")
        help.addItem(withTitle: "Edit keybindings.json", action: #selector(AppDelegate.editKeyBindings(_:)), keyEquivalent: "")
        NSApp.helpMenu = help

        return main
    }

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        return menu
    }

    static func item(for id: CommandID, keyMap: KeyMap, action: Selector = commandAction) -> NSMenuItem {
        let spec = CommandRegistry.spec(id)
        let item = NSMenuItem(title: spec?.title ?? id.rawValue, action: action, keyEquivalent: "")
        item.representedObject = id.rawValue
        if let combo = keyMap.menuKey(for: id), let (key, mods) = combo.menuKeyEquivalent {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = mods
        }
        // Plain keys (Tab, Space, ←…) can't be menu equivalents; show them as a tooltip instead.
        let plain = keyMap.keys(for: id).filter(\.isPlainTyping)
        if !plain.isEmpty {
            item.toolTip = "Also: " + plain.map(\.description).joined(separator: ", ")
        }
        return item
    }

    /// Standard Edit commands send their AppKit action, so text fields get them too.
    private static func add(_ menu: NSMenu, _ ids: [CommandID], _ keyMap: KeyMap) {
        for id in ids { menu.addItem(item(for: id, keyMap: keyMap, action: id.standardEditAction ?? commandAction)) }
    }
}

/// Selectors for undo/redo that the responder chain resolves (NSResponder declares them informally).
@objc protocol UndoActions {
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
}
