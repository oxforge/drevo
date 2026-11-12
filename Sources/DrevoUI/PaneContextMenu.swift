import AppKit
import DrevoCore
import UniformTypeIdentifiers

/// Right-click menus and the "open"-family commands (Open With, Edit, package contents, Finder).
extension PaneViewController {
    var windowController: MainWindowController? { view.window?.windowController as? MainWindowController }

    func browser(_ browser: FileBrowser, menuFor items: [FileItem]) -> NSMenu? {
        activate(focus: false)
        let menu = NSMenu()
        let keyMap = env.keyMap
        let target = windowController
        func add(_ ids: [CommandID]) {
            for id in ids {
                let item = MainMenu.item(for: id, keyMap: keyMap)
                item.target = target
                menu.addItem(item)
            }
        }
        if items.isEmpty {
            add([.newFolder, .newFile])
            let paste = menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
            paste.target = self
            menu.addItem(.separator())
            add([.openTerminal, .runCommand, .copyPath, .getInfo])
            menu.addItem(.separator())
            let sortItem = menu.addItem(withTitle: "Sort By", action: nil, keyEquivalent: "")
            let sortMenu = NSMenu()
            for item in SortButton.menuItems(for: sort, target: self, choose: #selector(contextSortChosen(_:)), reverse: #selector(contextSortDirection(_:))) {
                sortMenu.addItem(item)
            }
            sortItem.submenu = sortMenu
            add([.toggleHidden, .listView, .columnsView])
            return menu
        }
        add([.open])
        if let openWith = openWithMenu(for: items) {
            let item = menu.addItem(withTitle: "Open With", action: nil, keyEquivalent: "")
            item.submenu = openWith
        }
        add([.quickLook])
        if items.count == 1, items[0].isPackage { add([.showPackageContents]) }
        menu.addItem(.separator())
        let copy = menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        copy.target = self
        let cut = menu.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "")
        cut.target = self
        add([.duplicate, .makeAlias, .rename])
        menu.addItem(.separator())
        add([.copyToOtherPane, .moveToOtherPane])
        if items.count == 1, items[0].isContainer { add([.openInOtherPane, .addToSidebar]) }
        menu.addItem(.separator())
        add([.copyPath, .getInfo, .revealInFinder, .openTerminal])
        menu.addItem(.separator())
        add([.moveToTrash])
        return menu
    }

    @objc private func contextSortChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = SortKey(rawValue: raw), key != sort.key else { return }
        chooseSort(key)
    }

    @objc private func contextSortDirection(_ sender: NSMenuItem) {
        guard let ascending = sender.representedObject as? Bool, ascending != sort.ascending else { return }
        reverseSort()
    }

    // MARK: Open With

    private func openWithMenu(for items: [FileItem]) -> NSMenu? {
        guard let first = items.first(where: { !$0.isContainer }) ?? items.first else { return nil }
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: first.url)
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: first.url)
        let menu = NSMenu()
        var seen = Set<String>()
        for app in ([defaultApp].compactMap { $0 } + apps) where seen.insert(app.path).inserted {
            let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            let title = app == defaultApp ? "\(name) (default)" : name
            let item = menu.addItem(withTitle: title, action: #selector(openWithChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            if app == defaultApp, apps.count > 1 { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())
        let other = menu.addItem(withTitle: "Other…", action: #selector(openWithOther(_:)), keyEquivalent: "")
        other.target = self
        return menu
    }

    @objc private func openWithChosen(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        env.opener.open(selectedItems.map(\.url), withApplicationAt: app)
    }

    @objc private func openWithOther(_ sender: NSMenuItem) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        let urls = selectedItems.map(\.url)
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let app = panel.url else { return }
            self?.env.opener.open(urls, withApplicationAt: app)
        }
    }

    // MARK: Edit, packages, Finder

    /// F4: selected items (or this folder) in the configured editor.
    func editSelection() {
        let urls = selectedItems.isEmpty ? [currentDirectory] : selectedItems.map(\.url)
        let app = env.preferences.editorAppPath.map { URL(fileURLWithPath: $0) }
            ?? NSWorkspace.shared.urlForApplication(toOpen: UTType.plainText)
            ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        env.opener.open(urls, withApplicationAt: app)
    }

    func showPackageContents() {
        guard let item = selectedItems.first, item.isDirectory else { return }
        enterDirectory(item.url)
    }

    func revealInFinder() {
        let urls = selectedItems.isEmpty ? [currentDirectory] : selectedItems.map(\.url)
        if FileViewerSetting.isDrevo {
            // "Show in Finder" is redirected to Drevo, so ask Finder directly to open this folder.
            env.opener.open([currentDirectory], withApplicationAt: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    func showInfo() {
        let urls = selectedItems.isEmpty ? [currentDirectory] : selectedItems.map(\.url)
        for url in urls.prefix(10) { InfoPanel.show(for: url, relativeDates: env.preferences.relativeDates) }
    }
}
