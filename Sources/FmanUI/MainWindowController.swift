import AppKit
import FmanCore

/// Content area right of the sidebar: panes over a collapsible console, then the bars
/// (operations, command line, key hints).
@MainActor
final class WorkspaceViewController: NSViewController, NSSplitViewDelegate {
    let paneGroup: PaneGroupViewController
    let console = ConsoleViewController()
    let bottomStack = NSStackView()
    private let split = NSSplitView()
    private var consoleHeight: CGFloat = 220

    init(paneGroup: PaneGroupViewController) {
        self.paneGroup = paneGroup
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        addChild(paneGroup)
        addChild(console)
        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(paneGroup.view)
        split.addArrangedSubview(console.view)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(NSLayoutConstraint.Priority(rawValue: 260), forSubviewAt: 1)
        console.view.isHidden = true
        bottomStack.orientation = .vertical
        bottomStack.spacing = 0
        bottomStack.alignment = .leading
        bottomStack.distribution = .fill
        for v in [split, bottomStack] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomStack.topAnchor),
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

    var isConsoleVisible: Bool { !console.view.isHidden }

    func setConsoleVisible(_ visible: Bool) {
        guard visible != isConsoleVisible else { return }
        if !visible { consoleHeight = max(120, console.view.frame.height) }
        console.view.isHidden = !visible
        split.adjustSubviews()
        if visible {
            split.layoutSubtreeIfNeeded()
            split.setPosition(max(160, split.bounds.height - consoleHeight), ofDividerAt: 0)
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 160)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.height - 80)
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
    let commandBar: CommandBar
    let shell: ShellSession
    let keyHints = KeyHintBar()
    private var sidebarItem: NSSplitViewItem!
    private var observers: [NSObjectProtocol] = []
    private var watcher: DirectoryWatcher?

    init(env: AppEnvironment, directories: [URL], viewModes: [ViewMode] = [], sorts: [FileSort] = [], autosave: Bool = true) {
        self.env = env
        sidebar = SidebarViewController(env: env)
        let group = PaneGroupViewController(directories: directories, viewModes: viewModes, sorts: sorts, env: env)
        workspace = WorkspaceViewController(paneGroup: group)
        commandBar = CommandBar(preferences: env.preferences)
        shell = ShellSession(console: workspace.console, preferences: env.preferences, setup: env.shellSetup)

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
            if p === self?.paneGroup.activePane {
                self?.refreshWindowChrome()
                self?.refreshQuickLook()
            }
            self?.saveState()
            self?.updateWatchedFolders()
        }
        sidebar.onNavigate = { [weak self] url in
            guard let self else { return }
            self.paneGroup.activePane.navigate(to: url)
            self.paneGroup.activePane.focus()
        }
        observers.append(NotificationCenter.default.addObserver(forName: OperationsCenter.filesDidChange, object: env.operations, queue: .main) { [weak self] _ in
            // Through the guarded path: a reload mid-rename would commit a half-typed name.
            MainActor.assumeIsolated { self?.paneGroup.panes.forEach { $0.reloadForExternalChange() } }
        })
        observers.append(NotificationCenter.default.addObserver(forName: Preferences.didChange, object: env.preferences, queue: .main) { [weak self] note in
            let key = note.userInfo?[Preferences.changedKey] as? String
            MainActor.assumeIsolated { self?.preferencesChanged(key: key) }
        })
        _ = workspace.view
        workspace.addBottomBar(OperationsBar(operations: env.operations))
        workspace.addBottomBar(commandBar)
        workspace.addBottomBar(keyHints)
        commandBar.isHidden = !env.preferences.showCommandLine
        keyHints.isHidden = !env.preferences.showKeyHints
        keyHints.reload(keyMap: env.keyMap)
        keyHints.onCommand = { [weak self] id in
            self?.paneGroup.activePane.focus()
            self?.perform(id)
        }
        observers.append(NotificationCenter.default.addObserver(forName: AppEnvironment.keyMapDidChange, object: env, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.keyHints.reload(keyMap: self.env.keyMap)
            }
        })
        wireShell()
        startWatching()
        refreshWindowChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        watcher?.stop()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        paneGroup.activePane.focus()
    }

    /// Remembers panes for the next launch (the most recently changed window wins).
    func saveState() {
        env.preferences.savedWindowState = paneGroup.state.encoded()
    }

    private func wireShell() {
        commandBar.onRun = { [weak self] command in
            guard let self else { return }
            self.workspace.setConsoleVisible(true)
            if !self.shell.run(command, in: self.paneGroup.activePane.currentDirectory) {
                NSSound.beep()
                self.workspace.console.append("A command is still running — ⌘. stops it.\n", isError: true)
            }
        }
        commandBar.onRunInTerminal = { [weak self] command in
            guard let self else { return }
            let dir = self.paneGroup.activePane.currentDirectory
            if command.isEmpty {
                TerminalLauncher.open(dir, env: self.env)
            } else {
                do { try TerminalLauncher.run(command, in: dir, env: self.env) } catch {
                    self.env.operations.prompts.showError("Couldn’t open the terminal.", detail: error.localizedDescription, in: self.window)
                }
            }
        }
        commandBar.onEscape = { [weak self] in self?.paneGroup.activePane.focus() }
        commandBar.onFocus = { [weak self] in self?.shell.prepare() }
        commandBar.onToggleConsole = { [weak self] in self?.perform(.toggleConsole) }
        commandBar.selectionProvider = { [weak self] fullPaths in
            guard let pane = self?.paneGroup.activePane else { return [] }
            return pane.selectedItems.map { fullPaths ? $0.url.path : $0.name }
        }
        workspace.console.onStop = { [weak self] in self?.shell.stop() }
        workspace.console.onHide = { [weak self] in
            self?.workspace.setConsoleVisible(false)
            self?.paneGroup.activePane.focus()
        }
        shell.onFinish = { [weak self] in self?.env.operations.postChange() }
    }

    // MARK: Live updates

    private func startWatching() {
        watcher = DirectoryWatcher { [weak self] changed in
            onMainRunLoop { self?.foldersChanged(changed) }
        }
        updateWatchedFolders()
    }

    func updateWatchedFolders() {
        watcher?.watch(paneGroup.panes.flatMap(\.shownDirectories))
    }

    private func foldersChanged(_ changed: Set<String>) {
        for pane in paneGroup.panes where pane.shownDirectories.contains(where: { changed.contains(DirectoryWatcher.normalize($0.path)) }) {
            pane.reloadForExternalChange()
        }
    }

    /// Folder for "Open in Terminal": the selected folder, else the current one.
    private var terminalFolder: URL {
        let pane = paneGroup.activePane
        if pane.selectedItems.count == 1, pane.selectedItems[0].isContainer { return pane.selectedItems[0].url }
        return pane.currentDirectory
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
        case .quickLook: toggleQuickLook()
        case .openTerminal: TerminalLauncher.open(terminalFolder, env: env)
        case .runCommand:
            if !env.preferences.showCommandLine { prefs.showCommandLine = true }
            commandBar.focus()
        case .runInTerminal: commandBar.submit(inTerminal: true)
        case .toggleConsole:
            workspace.setConsoleVisible(!workspace.isConsoleVisible)
            if !workspace.isConsoleVisible { paneGroup.activePane.focus() }
        case .stopCommand: shell.stop()
        case .commandPalette: CommandPalette.show(for: self)
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
        case .rename, .newFolder, .newFile, .moveToTrash, .deleteImmediately, .duplicate, .makeAlias, .copyPath, .pasteMove,
             .edit, .showPackageContents, .revealInFinder, .getInfo:
            return pane.canPerformFileCommand(id)
        case .quickLook: return !pane.selectedItems.isEmpty
        case .openTerminal, .runCommand, .toggleConsole, .goToPath, .filter, .commandPalette: return true
        case .sortByName, .sortByKind, .sortByModified, .sortByCreated, .sortBySize, .reverseSort: return true
        case .stopCommand: return shell.isRunning
        case .runInTerminal: return commandBar.hasFocus
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
        case .toggleConsole: menuItem.state = workspace.isConsoleVisible ? .on : .off
        case .toggleSidebar: menuItem.state = sidebarItem.isCollapsed ? .off : .on
        case .listView: menuItem.state = paneGroup.activePane.viewMode == .list ? .on : .off
        case .columnsView: menuItem.state = paneGroup.activePane.viewMode == .columns ? .on : .off
        case .sortByName, .sortByKind, .sortByModified, .sortByCreated, .sortBySize:
            let key: SortKey = [CommandID.sortByName: .name, .sortByKind: .kind, .sortByModified: .modified,
                                .sortByCreated: .created, .sortBySize: .size][id]!
            menuItem.state = paneGroup.activePane.sort.key == key ? .on : .off
        default: break
        }
        let category = CommandRegistry.spec(id)?.category
        if isEditingText, category != .window, category != .view, category != .shell {
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
        case "commandHistory", "windowState":
            break
        case "favorites":
            sidebar.reloadSections()
        case "showKeyHints":
            keyHints.isHidden = !env.preferences.showKeyHints
        case "showCommandLine":
            commandBar.isHidden = !env.preferences.showCommandLine
            if commandBar.isHidden, commandBar.hasFocus { paneGroup.activePane.focus() }
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
        commandBar.setDirectory(pane.currentDirectory)
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
