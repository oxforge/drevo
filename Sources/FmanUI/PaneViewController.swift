import AppKit
import FmanCore

/// Runs commands for a window; panes send keys here so window- and group-level commands
/// (Tab, palette…) work from inside a file view.
@MainActor
protocol CommandDispatching: AnyObject {
    @discardableResult
    func perform(_ id: CommandID) -> Bool
}

/// One pane: header (path bar), a browser (List or Columns), status bar.
@MainActor
final class PaneViewController: NSViewController, FileBrowserDelegate {
    let env: AppEnvironment
    weak var dispatcher: CommandDispatching?
    /// Called when the pane wants to become the active one (click, focus).
    var onActivate: ((PaneViewController) -> Void)?
    /// Called when the folder or selection changed (window title, toolbar).
    var onChange: ((PaneViewController) -> Void)?

    private(set) var history: NavigationHistory
    private(set) var viewMode: ViewMode
    private(set) var sort = FileSort()
    private(set) var filter = ""
    var reloadPendingAfterRename = false
    var shownDirectories: [URL] { browser.shownDirectories }
    private(set) var browser: FileBrowser!

    let header = PaneHeaderView()
    let statusBar = StatusBarView()
    let sortButton = SortButton()
    private let browserContainer = NSView()

    var isActive = false {
        didSet { header.isActive = isActive }
    }

    var currentDirectory: URL { browser.currentDirectory }
    var selectedItems: [FileItem] { browser.selectedItems }

    init(directory: URL, viewMode: ViewMode, sort: FileSort = FileSort(), env: AppEnvironment) {
        self.env = env
        self.viewMode = viewMode
        self.sort = sort
        self.history = NavigationHistory(start: directory)
        super.init(nibName: nil, bundle: nil)
        // The browser exists before the view loads so the pane can answer questions early;
        // its view is embedded in loadView.
        attach(makeBrowser(directory: directory))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        for v in [header, browserContainer, statusBar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            browserContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            browserContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            browserContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            browserContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        header.pathBar.onNavigate = { [weak self] url in
            self?.activate(focus: true)
            self?.navigate(to: url, selecting: nil)
        }
        header.onClick = { [weak self] in self?.activate(focus: true) }
        header.onPathCommit = { [weak self] text in self?.commitPath(text) }
        header.onPathComplete = { [weak self] text in
            guard let self else { return [] }
            return PathCompletion.candidates(for: text, relativeTo: self.currentDirectory, showHidden: self.env.preferences.showHidden)
        }
        header.onEditingEnded = { [weak self] in self?.focus() }
        header.onFilterChange = { [weak self] text in self?.setFilter(text) }
        header.onFilterDone = { [weak self] clear in
            guard let self else { return }
            if clear { self.clearFilter() }
            self.focus()
        }
        statusBar.isHidden = !env.preferences.showStatusBar
        sortButton.update(sort)
        sortButton.onChoose = { [weak self] key in self?.chooseSort(key) }
        sortButton.onReverse = { [weak self] in self?.reverseSort() }
        header.accessoryStack.insertArrangedSubview(sortButton, at: 0)
        view = root
        embed(browser)
        refreshChrome()
    }

    // MARK: Browser

    private func makeBrowser(directory: URL) -> FileBrowser {
        let options = env.preferences.listingOptions(sort: sort, filter: filter)
        switch viewMode {
        case .list:
            let list = FileListViewController(directory: directory, options: options, preferences: env.preferences)
            list.onSortChange = { [weak self] s in
                guard let self else { return }
                self.sort = s
                self.sortButton.update(s)
                self.onChange?(self)
            }
            return list
        case .columns:
            return ColumnBrowserViewController(directory: directory, options: options, preferences: env.preferences)
        }
    }

    private func attach(_ b: FileBrowser) {
        b.delegate = self
        if let vc = b as? NSViewController { addChild(vc) }
        browser = b
    }

    private func embed(_ b: FileBrowser) {
        let v = b.view
        v.translatesAutoresizingMaskIntoConstraints = false
        browserContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: browserContainer.topAnchor),
            v.bottomAnchor.constraint(equalTo: browserContainer.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: browserContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: browserContainer.trailingAnchor),
        ])
    }

    private func installBrowser(directory: URL, selecting: URL?) {
        let hadFocus = browser.hasFocus
        if let old = browser as? NSViewController {
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        let b = makeBrowser(directory: directory)
        attach(b)
        if isViewLoaded { embed(b) }
        if let selecting { b.select([selecting]) }
        refreshChrome()
        if hadFocus { b.focus() }
    }

    func setViewMode(_ mode: ViewMode) {
        guard mode != viewMode else { return }
        let dir = currentDirectory
        let selected = selectedItems.first?.url
        viewMode = mode
        installBrowser(directory: dir, selecting: selected)
        onChange?(self)
    }

    // MARK: Navigation

    /// Show `url` and remember it in history. Files are revealed: their folder opens with them selected.
    func navigate(to url: URL, selecting: URL? = nil) {
        if !filter.isEmpty || header.isFiltering { clearFilter(reload: false) }
        var target = url
        var select = selecting
        if let item = try? FileItem(url: url), !item.isContainer {
            target = url.deletingLastPathComponent()
            select = url
        }
        history.visit(target)
        browser.display(target, selecting: select)
        refreshChrome()
        onChange?(self)
    }

    /// Shows a directory even if it's a package (Show Package Contents).
    func enterDirectory(_ url: URL) {
        history.visit(url)
        browser.display(url, selecting: nil)
        refreshChrome()
        onChange?(self)
    }

    func reload() {
        browser.reload(options: env.preferences.listingOptions(sort: sort, filter: filter))
        refreshChrome()
    }

    // MARK: Sorting

    /// Sort this pane by `key`; the current key again reverses the order.
    func chooseSort(_ key: SortKey) {
        setSort(sort.choosing(key))
    }

    func reverseSort() {
        var s = sort
        s.ascending.toggle()
        setSort(s)
    }

    func setSort(_ newSort: FileSort) {
        sort = newSort
        reload()
        sortButton.update(sort)
        onChange?(self)
    }

    // MARK: Path editing and filter

    /// ⌘L / ⇧⌘G, or typing "/" or "~" in the file list.
    func beginPathEditing(prefill: String? = nil) {
        activate(focus: false)
        if let prefill {
            header.beginPathEditing(prefill, selectAll: false)
        } else {
            header.beginPathEditing(Formatting.abbreviatedPath(currentDirectory) + "/", selectAll: true)
        }
    }

    private func commitPath(_ text: String) {
        let path = PathCompletion.expand(text, relativeTo: currentDirectory)
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            header.pathField.currentEditor()?.selectAll(nil)
            return
        }
        header.endPathEditing()
        navigate(to: url)
        focus()
    }

    func beginFilter() {
        activate(focus: false)
        header.beginFilter()
    }

    func setFilter(_ text: String) {
        filter = text
        reload()
        if let first = browser.visibleItems.first, browser.selectedItems.isEmpty { browser.select([first.url]) }
    }

    func clearFilter(reload doReload: Bool = true) {
        header.clearFilter()
        guard !filter.isEmpty else { return }
        filter = ""
        if doReload { reload() }
    }

    /// Files changed (FSEvents, an operation, undo). While a rename is being typed the
    /// reload waits; ending the edit early would commit a half-typed name.
    func reloadForExternalChange() {
        guard !InlineRenamer.isEditing else {
            reloadPendingAfterRename = true
            return
        }
        reload()
    }

    func focus() { browser.focus() }

    func activate(focus: Bool) {
        onActivate?(self)
        if focus { browser.focus() }
    }

    private func goBack() {
        guard let url = history.goBack() else { return }
        let from = currentDirectory
        browser.display(url, selecting: from.deletingLastPathComponent() == url ? from : nil)
        refreshChrome()
        onChange?(self)
    }

    private func goForward() {
        guard let url = history.goForward() else { return }
        browser.display(url, selecting: nil)
        refreshChrome()
        onChange?(self)
    }

    func goToEnclosingFolder() {
        let current = currentDirectory.standardizedFileURL
        let parent = current.deletingLastPathComponent()
        guard parent.path != current.path else { return }
        navigate(to: parent, selecting: current)
    }

    func open(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        if items.count == 1, let item = items.first {
            if item.isContainer { navigate(to: item.url); return }
            // Listings skip alias detection for speed; check when opening.
            let isAlias = (try? item.url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true && !item.isSymbolicLink
            if isAlias, let target = try? URL(resolvingAliasFileAt: item.url),
               let resolved = try? FileItem(url: target), resolved.isContainer {
                navigate(to: target)
                return
            }
        }
        let files = items.filter { !$0.isContainer }
        // Archives fman can expand itself: Archive Utility would reveal the result in a
        // new Finder window.
        let archives = files.filter { ArchiveExtraction.format(of: $0.url) != nil }
        let others = files.filter { ArchiveExtraction.format(of: $0.url) == nil }
        if !archives.isEmpty {
            operations.extract(archives.map(\.url), window: view.window) { [weak self] outputs in
                guard let self else { return }
                let here = outputs.filter { $0.deletingLastPathComponent().standardizedFileURL.path == self.currentDirectory.standardizedFileURL.path }
                self.reload(selecting: here)
            }
        }
        if !others.isEmpty { env.opener.open(others.map(\.url)) }
    }

    // MARK: Commands

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    /// Pane-level commands; returns false for commands it doesn't own.
    func perform(_ id: CommandID) -> Bool {
        switch id {
        case .open: open(selectedItems)
        case .enclosingFolder: goToEnclosingFolder()
        case .levelUp: if !browser.levelUp() { goToEnclosingFolder() }
        case .levelDown:
            if !browser.levelDown() {
                return false
            }
        case .back: goBack()
        case .forward: goForward()
        case .goHome: navigate(to: FileManager.default.homeDirectoryForCurrentUser)
        case .goDesktop: navigate(to: Self.userFolder(.desktopDirectory))
        case .goDocuments: navigate(to: Self.userFolder(.documentDirectory))
        case .goDownloads: navigate(to: Self.userFolder(.downloadsDirectory))
        case .goApplications: navigate(to: URL(fileURLWithPath: "/Applications"))
        case .goUtilities: navigate(to: URL(fileURLWithPath: "/Applications/Utilities"))
        case .goVolumes: navigate(to: URL(fileURLWithPath: "/Volumes"))
        case .listView: setViewMode(.list)
        case .columnsView: setViewMode(.columns)
        case .goToPath: beginPathEditing()
        case .filter: beginFilter()
        case .sortByName: chooseSort(.name)
        case .sortByKind: chooseSort(.kind)
        case .sortByModified: chooseSort(.modified)
        case .sortByCreated: chooseSort(.created)
        case .sortBySize: chooseSort(.size)
        case .reverseSort: reverseSort()
        default: return performFileCommand(id)
        }
        return true
    }

    static func userFolder(_ d: FileManager.SearchPathDirectory) -> URL {
        FileManager.default.urls(for: d, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
    }

    func applyPreferences() {
        statusBar.isHidden = !env.preferences.showStatusBar
        browser.applyRowSize(env.preferences.rowSize)
        reload()
    }

    // MARK: Chrome

    func refreshChrome() {
        guard isViewLoaded else { return }
        header.pathBar.show(currentDirectory)
        updateStatus()
    }

    private func updateStatus() {
        statusBar.update(items: browser.visibleItems, selected: browser.selectedItems, directory: currentDirectory)
        if !filter.isEmpty { statusBar.left.stringValue = "Filter “\(filter)”: " + statusBar.left.stringValue }
    }

    // MARK: FileBrowserDelegate

    func browser(_ browser: FileBrowser, didMoveTo directory: URL) {
        history.visit(directory)
        refreshChrome()
        onChange?(self)
    }

    func browserSelectionDidChange(_ browser: FileBrowser) {
        updateStatus()
        onChange?(self)
    }

    func browserDidActivate(_ browser: FileBrowser) {
        onActivate?(self)
    }

    func browser(_ browser: FileBrowser, handleKey event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if mods.isEmpty, let c = event.characters, c == "/" || c == "~" {
            beginPathEditing(prefill: c == "~" ? "~/" : "/")
            return true
        }
        if event.keyCode == 53, !filter.isEmpty { // Esc clears an active filter
            clearFilter()
            return true
        }
        guard let id = env.keyMap.command(for: event) else { return false }
        // Arrow keys fall through to the table when the command has nothing to do.
        if id == .levelDown { return perform(.levelDown) }
        return dispatcher?.perform(id) ?? perform(id)
    }

    func browser(_ browser: FileBrowser, open items: [FileItem]) {
        open(items)
    }

    func browser(_ browser: FileBrowser, drop urls: [URL], onto destination: URL, kind: TransferKind) {
        activate(focus: true)
        operations.transfer(kind, urls, to: destination, window: view.window) { [weak self] result in
            guard let self else { return }
            if destination.standardizedFileURL.path == self.currentDirectory.standardizedFileURL.path {
                self.reload(selecting: result.outputs)
            }
        }
    }

    func browserDragEnded(_ browser: FileBrowser) {
        // Items dragged to another app may have moved out of this folder.
        reload()
    }
}
