import AppKit
import FmanCore

/// Content area right of the sidebar: panes on top, bars (console, command line, key hints) below.
@MainActor
final class WorkspaceViewController: NSViewController {
    let paneGroup: PaneGroupViewController
    let bottomStack = NSStackView()

    init(paneGroup: PaneGroupViewController) {
        self.paneGroup = paneGroup
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        addChild(paneGroup)
        bottomStack.orientation = .vertical
        bottomStack.spacing = 0
        bottomStack.alignment = .leading
        bottomStack.distribution = .fill
        let pv = paneGroup.view
        for v in [pv, bottomStack] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            pv.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            pv.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pv.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pv.bottomAnchor.constraint(equalTo: bottomStack.topAnchor),
            bottomStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomStack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    /// Adds a full-width bar at the bottom (in order of calls, top to bottom).
    func addBottomBar(_ bar: NSView) {
        bottomStack.addArrangedSubview(bar)
        bar.widthAnchor.constraint(equalTo: bottomStack.widthAnchor).isActive = true
    }
}

/// One browser window: sidebar + panes, toolbar, and the command dispatcher.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, CommandDispatching, NSMenuItemValidation, NSToolbarDelegate {
    let env: AppEnvironment
    let splitController = NSSplitViewController()
    let sidebar: SidebarViewController
    let workspace: WorkspaceViewController
    var paneGroup: PaneGroupViewController { workspace.paneGroup }
    private var sidebarItem: NSSplitViewItem!
    private var observers: [NSObjectProtocol] = []

    init(env: AppEnvironment, directories: [URL], viewModes: [ViewMode] = [], autosave: Bool = true) {
        self.env = env
        sidebar = SidebarViewController(env: env)
        let group = PaneGroupViewController(directories: directories, viewModes: viewModes, env: env)
        workspace = WorkspaceViewController(paneGroup: group)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.minSize = NSSize(width: 640, height: 360)
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        window.tabbingMode = .disallowed
        super.init(window: window)

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = !env.preferences.showSidebar
        splitController.addSplitViewItem(sidebarItem)
        let content = NSSplitViewItem(viewController: workspace)
        content.minimumThickness = 480
        splitController.addSplitViewItem(content)
        splitController.splitView.autosaveName = autosave ? "fman.sidebar" : nil

        window.contentViewController = splitController
        window.setContentSize(NSSize(width: 1240, height: 760))
        window.delegate = self

        let toolbar = NSToolbar(identifier: "fman.main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        if autosave { toolbar.autosavesConfiguration = true }
        window.toolbar = toolbar

        if autosave {
            window.setFrameAutosaveName("fman.main")
        }
        if !autosave || !window.setFrameUsingName("fman.main") { window.center() }

        group.setDispatcher(self)
        group.onActivePaneChange = { [weak self] _ in
            self?.refreshWindowChrome()
            self?.saveState()
        }
        group.onPaneChange = { [weak self] p in
            if p === self?.paneGroup.activePane { self?.refreshWindowChrome() }
            self?.saveState()
        }
        sidebar.onNavigate = { [weak self] url in
            guard let self else { return }
            self.paneGroup.activePane.navigate(to: url)
            self.paneGroup.activePane.focus()
        }
        observers.append(NotificationCenter.default.addObserver(forName: OperationsCenter.filesDidChange, object: env.operations, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.paneGroup.panes.forEach { $0.reload() } }
        })
        observers.append(NotificationCenter.default.addObserver(forName: Preferences.didChange, object: env.preferences, queue: .main) { [weak self] note in
            let key = note.userInfo?[Preferences.changedKey] as? String
            MainActor.assumeIsolated { self?.preferencesChanged(key: key) }
        })
        _ = workspace.view
        workspace.addBottomBar(OperationsBar(operations: env.operations))
        refreshWindowChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        paneGroup.activePane.focus()
    }

    /// Remembers panes for the next launch (the most recently changed window wins).
    func saveState() {
        env.preferences.savedWindowState = paneGroup.state.encoded()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        env.operations.undoManager
    }

    // MARK: Commands

    @objc func performCommand(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String ?? (sender as? NSToolbarItem)?.itemIdentifier.rawValue else { return }
        perform(CommandID(raw))
    }

    @discardableResult
    func perform(_ id: CommandID) -> Bool {
        let prefs = env.preferences
        switch id {
        case .toggleHidden: prefs.showHidden.toggle()
        case .toggleStatusBar: prefs.showStatusBar.toggle()
        case .toggleKeyHints: prefs.showKeyHints.toggle()
        case .toggleCommandLine: prefs.showCommandLine.toggle()
        case .toggleSidebar:
            sidebarItem.animator().isCollapsed.toggle()
            prefs.showSidebar = !sidebarItem.isCollapsed
        case .biggerRows: prefs.rowSize = RowSize(rawValue: min(2, prefs.rowSize.rawValue + 1))!
        case .smallerRows: prefs.rowSize = RowSize(rawValue: max(0, prefs.rowSize.rawValue - 1))!
        case .newWindow: (NSApp.delegate as? AppDelegate)?.newWindow(nil)
        case .addToSidebar:
            let pane = paneGroup.activePane
            let folders = pane.selectedItems.filter(\.isContainer).map(\.url)
            (folders.isEmpty ? [pane.currentDirectory] : folders).forEach { sidebar.addFavorite($0) }
        default:
            if paneGroup.perform(id) { return true }
            if paneGroup.activePane.perform(id) { return true }
            NSSound.beep()
            return false
        }
        return true
    }

    /// Commands implemented so far; menu items for the rest are disabled.
    func canPerform(_ id: CommandID) -> Bool {
        let pane = paneGroup.activePane
        switch id {
        case .back: return pane.canGoBack
        case .forward: return pane.canGoForward
        case .open: return !pane.selectedItems.isEmpty
        case .nextPane, .previousPane, .swapPanes, .openInOtherPane, .removePane: return paneGroup.panes.count > 1
        case .addPane: return paneGroup.panes.count < 4
        case .copyToOtherPane, .moveToOtherPane: return !pane.selectedItems.isEmpty
        case .rename, .newFolder, .newFile, .moveToTrash, .deleteImmediately, .duplicate, .makeAlias, .copyPath, .pasteMove:
            return pane.canPerformFileCommand(id)
        case .enclosingFolder, .levelUp, .levelDown, .goHome, .goDesktop, .goDocuments, .goDownloads,
             .goApplications, .goUtilities, .goVolumes, .listView, .columnsView, .toggleHidden,
             .toggleStatusBar, .toggleKeyHints, .toggleCommandLine, .toggleSidebar, .biggerRows,
             .smallerRows, .newWindow, .addToSidebar:
            return true
        default:
            return false
        }
    }

    /// While a text field edits (rename, path, command line), file commands stay out of the way.
    private var isEditingText: Bool {
        window?.firstResponder is NSText
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == MainMenu.commandAction, let raw = menuItem.representedObject as? String else { return true }
        let id = CommandID(raw)
        let prefs = env.preferences
        switch id {
        case .toggleHidden: menuItem.state = prefs.showHidden ? .on : .off
        case .toggleStatusBar: menuItem.state = prefs.showStatusBar ? .on : .off
        case .toggleKeyHints: menuItem.state = prefs.showKeyHints ? .on : .off
        case .toggleCommandLine: menuItem.state = prefs.showCommandLine ? .on : .off
        case .toggleSidebar: menuItem.state = sidebarItem.isCollapsed ? .off : .on
        case .listView: menuItem.state = paneGroup.activePane.viewMode == .list ? .on : .off
        case .columnsView: menuItem.state = paneGroup.activePane.viewMode == .columns ? .on : .off
        default: break
        }
        if isEditingText, CommandRegistry.spec(id)?.category != .window, CommandRegistry.spec(id)?.category != .view {
            return false
        }
        return canPerform(id)
    }

    // MARK: Preferences

    private func preferencesChanged(key: String?) {
        switch key {
        case "returnRenames":
            env.reloadKeyMap()
        case "showSidebar":
            if sidebarItem.isCollapsed == env.preferences.showSidebar { sidebarItem.isCollapsed = !env.preferences.showSidebar }
        case "commandHistory", "windowState", "favorites":
            if key == "favorites" { sidebar.reloadSections() }
        default:
            paneGroup.panes.forEach { $0.applyPreferences() }
            refreshToolbar()
        }
    }

    // MARK: Window chrome

    func refreshWindowChrome() {
        let pane = paneGroup.activePane
        window?.title = Formatting.displayName(pane.currentDirectory)
        window?.representedURL = pane.currentDirectory
        refreshToolbar()
    }

    private func refreshToolbar() {
        guard let items = window?.toolbar?.items else { return }
        let pane = paneGroup.activePane
        for item in items {
            switch item.itemIdentifier {
            case .fmanNavigation:
                if let group = item as? NSToolbarItemGroup, group.subitems.count == 2 {
                    group.subitems[0].isEnabled = pane.canGoBack
                    group.subitems[1].isEnabled = pane.canGoForward
                }
            case .fmanViewMode:
                (item as? NSToolbarItemGroup)?.selectedIndex = pane.viewMode == .list ? 0 : 1
            case .fmanHidden:
                item.image = NSImage(systemSymbolName: env.preferences.showHidden ? "eye" : "eye.slash", accessibilityDescription: "Hidden files")
            default: break
            }
        }
    }

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

    private var commandForToolbarItem: [NSToolbarItem.Identifier: CommandID] = [:]

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
