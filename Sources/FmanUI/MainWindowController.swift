import AppKit
import FmanCore

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
        observers.append(NotificationCenter.default.addObserver(forName: InlineRenamer.didEndEditing, object: nil, queue: .main) { [weak self] _ in
            // Every pane held its reload back while the name was typed, not only the
            // one that was renaming.
            MainActor.assumeIsolated { self?.paneGroup.panes.forEach { $0.reloadIfPostponed() } }
        })
        observers.append(NotificationCenter.default.addObserver(forName: Preferences.didChange, object: env.preferences, queue: .main) { [weak self] note in
            let key = note.userInfo?[Preferences.changedKey] as? Preferences.Key
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
                self.paneGroup.panes.forEach { $0.keyMapChanged() }
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

    /// The folders watched for changes right now (paths as `DirectoryWatcher.normalize` gives them).
    var watchedFolders: Set<String> { watcher?.watched ?? [] }

    /// FSEvents reported changes in `changed` (paths as `DirectoryWatcher.normalize` gives them).
    func foldersChanged(_ changed: Set<String>) {
        for pane in paneGroup.panes where pane.shownDirectories.contains(where: { changed.contains(DirectoryWatcher.normalize($0.path)) }) {
            // Columns view shows many folders; it re-reads only the ones that changed.
            pane.reloadForExternalChange(in: changed)
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

    /// Nothing reads a command's output once its window is gone: stop it.
    func windowWillClose(_ notification: Notification) {
        shell.stop()
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

    /// Whether `id` can run right now, given the panes, the selection and the shell;
    /// menu and toolbar items are enabled by it. Commands the window doesn't know are
    /// refused.
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

    private func preferencesChanged(key: Preferences.Key?) {
        switch key {
        case .returnRenames:
            env.reloadKeyMap()
        case .showSidebar:
            if sidebarItem.isCollapsed == env.preferences.showSidebar { sidebarItem.isCollapsed = !env.preferences.showSidebar }
        case .favorites:
            sidebar.reloadSections()
        case .showKeyHints:
            keyHints.isHidden = !env.preferences.showKeyHints
        case .showCommandLine:
            commandBar.isHidden = !env.preferences.showCommandLine
            if commandBar.isHidden, commandBar.hasFocus { paneGroup.activePane.focus() }
        default:
            // Everything else changes what the panes show.
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

    /// The command each toolbar button runs, filled as the items are made
    /// (`MainWindowToolbar.swift`).
    var commandForToolbarItem: [NSToolbarItem.Identifier: CommandID] = [:]
}
