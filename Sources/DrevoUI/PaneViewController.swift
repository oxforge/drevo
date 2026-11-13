import AppKit
import DrevoCore

/// Runs commands for a window; panes send keys here so window- and group-level commands
/// (Tab, palette…) work from inside a file view.
@MainActor
protocol CommandDispatching: AnyObject {
    @discardableResult
    func perform(_ id: CommandID) -> Bool
}

/// One pane: header (path bar), tabs when there are several, a browser (List or
/// Columns), status bar.
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
    /// What the pane is searching the current folder's tree for; nil while it shows a folder.
    private(set) var searchQuery: String?
    var searchResults: SearchResultsViewController? { browser as? SearchResultsViewController }
    var reloadPendingAfterRename = false
    var shownDirectories: [URL] { browser.shownDirectories }
    private(set) var browser: FileBrowser!

    let header = PaneHeaderView()
    let statusBar = StatusBarView()
    let tabBar = PaneTabBar()
    private lazy var tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: 0)
    /// Every tab as it was when it was last left. The active tab's entry is out of date
    /// while it is shown (`history`, `viewMode` and `sort` are its live state); `tabs`
    /// gives them all as they are now.
    private var storedTabs: [PaneTab]
    private(set) var activeTabIndex = 0
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
        self.storedTabs = [PaneTab(history: history, viewMode: viewMode, sort: sort)]
        super.init(nibName: nil, bundle: nil)
        // The browser exists before the view loads so the pane can answer questions early;
        // its view is embedded in loadView.
        attach(makeBrowser(directory: directory))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        for v in [header, tabBar, browserContainer, statusBar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: header.bottomAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBarHeight,
            browserContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
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
        header.pathBar.onDrop = { [weak self] urls, destination, kind in
            guard let self else { return }
            self.browser(self.browser, drop: urls, onto: destination, kind: kind)
        }
        tabBar.onSelect = { [weak self] index in
            self?.activate(focus: true)
            self?.selectTab(index)
        }
        tabBar.onClose = { [weak self] index in self?.closeTab(at: index) }
        header.onClick = { [weak self] in self?.activate(focus: true) }
        header.onPathAreaClick = { [weak self] in self?.beginPathEditing() }
        header.pathBar.onEditRequest = { [weak self] in self?.beginPathEditing() }
        header.onPathCommit = { [weak self] text in self?.commitPath(text) }
        header.onPathComplete = { [weak self] text in
            guard let self else { return [] }
            return PathCompletion.candidates(for: text, relativeTo: self.currentDirectory, showHidden: self.env.preferences.showHidden)
        }
        header.onEditingEnded = { [weak self] in self?.focus() }
        header.onFilterChange = { [weak self] text in self?.setFilter(text) }
        header.onFilterDone = { [weak self] clear in
            guard let self else { return }
            if clear {
                // Esc in the search field: back to the folder, or just out of the field
                // if nothing was searched yet.
                if self.searchQuery != nil { self.endSearch() } else { self.clearFilter() }
            }
            self.focus()
        }
        header.onSearchCommit = { [weak self] text in self?.search(text) }
        statusBar.isHidden = !env.preferences.showStatusBar
        sortButton.update(sort)
        sortButton.showShortcuts(env.keyMap)
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
        if let searchQuery {
            let results = SearchResultsViewController(root: directory, query: searchQuery, options: options, preferences: env.preferences)
            results.spotlight = env.spotlight
            results.runsSynchronously = env.runSearchesSynchronously
            results.onProgress = { [weak self] in self?.updateStatus() }
            return results
        }
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
        searchResults?.stop()
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

    // MARK: Search

    /// ⌥⌘F: the header's field asks what to look for below this folder.
    func beginSearch() {
        activate(focus: false)
        if searchQuery == nil, !filter.isEmpty || header.isFiltering { clearFilter() }
        header.showSearch(searchQuery ?? "", focus: true)
    }

    /// Shows what `query` finds in the current folder and the folders inside it, in
    /// place of the folder's contents. An empty query goes back to the folder.
    func search(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            if searchQuery != nil { endSearch() } else { clearFilter() }
            focus()
            return
        }
        let root = currentDirectory
        if !filter.isEmpty { clearFilter(reload: false) }
        searchQuery = query
        header.showSearch(query, focus: false)
        installBrowser(directory: root, selecting: nil)
        searchResults?.start()
        focus()
        onChange?(self)
    }

    /// Back from the results to the folder that was searched.
    func endSearch() {
        guard searchQuery != nil else { return }
        let root = currentDirectory
        searchQuery = nil
        header.clearFilter()
        installBrowser(directory: root, selecting: nil)
        onChange?(self)
    }

    func setViewMode(_ mode: ViewMode) {
        guard mode != viewMode else { return }
        endSearch()
        let dir = currentDirectory
        let selected = selectedItems.first?.url
        viewMode = mode
        installBrowser(directory: dir, selecting: selected)
        onChange?(self)
    }

    // MARK: Tabs

    /// Every tab of the pane as it is now.
    var tabs: [PaneTab] {
        var all = storedTabs
        all[activeTabIndex] = PaneTab(history: history, viewMode: viewMode, sort: sort, selection: selectedItems.first?.url)
        return all
    }

    var tabCount: Int { storedTabs.count }

    /// ⌘T: another tab on the same folder, right of the current one, with its own history.
    func newTab() {
        endSearch()
        storedTabs = tabs
        let fresh = PaneTab(history: NavigationHistory(start: currentDirectory), viewMode: viewMode, sort: sort,
                            selection: selectedItems.first?.url)
        activeTabIndex += 1
        storedTabs.insert(fresh, at: activeTabIndex)
        // The browser already shows this folder in this view: only the history starts over.
        history = fresh.history
        tabsChanged()
    }

    func selectTab(_ index: Int) {
        guard storedTabs.indices.contains(index), index != activeTabIndex else { return }
        storedTabs = tabs
        activeTabIndex = index
        showActiveTab()
    }

    /// Closes a tab; false when it is the only one (⌘W then closes the window).
    @discardableResult
    func closeTab(at index: Int) -> Bool {
        guard storedTabs.count > 1, storedTabs.indices.contains(index) else { return false }
        storedTabs = tabs
        storedTabs.remove(at: index)
        if index == activeTabIndex {
            // The tab to the right takes its place, as in a browser.
            activeTabIndex = min(index, storedTabs.count - 1)
            showActiveTab()
        } else {
            if index < activeTabIndex { activeTabIndex -= 1 }
            tabsChanged()
        }
        return true
    }

    /// Replaces the pane's tabs (saved window state).
    func restoreTabs(_ tabs: [PaneTab], active: Int) {
        guard !tabs.isEmpty else { return }
        storedTabs = tabs
        activeTabIndex = min(max(0, active), tabs.count - 1)
        showActiveTab()
    }

    /// Brings the active tab's saved state on screen.
    private func showActiveTab() {
        let tab = storedTabs[activeTabIndex]
        // A search belongs to the tab it was made in and isn't kept.
        searchQuery = nil
        if !filter.isEmpty || header.isFiltering { clearFilter(reload: false) }
        history = tab.history
        sort = tab.sort
        viewMode = tab.viewMode
        // The folder may have gone while the tab was in the background.
        var directory = tab.directory
        while !directory.isDirectoryOnDisk, directory.path != "/" { directory = directory.deletingLastPathComponent() }
        history.replaceCurrent(with: directory)
        installBrowser(directory: directory, selecting: tab.selection)
        sortButton.update(sort)
        tabsChanged()
    }

    private func tabsChanged() {
        refreshChrome()
        onChange?(self)
    }

    // MARK: Navigation

    /// Show `url` and remember it in history. Files are revealed: their folder opens with them selected.
    func navigate(to url: URL, selecting: URL? = nil) {
        endSearch()
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
        endSearch()
        history.visit(url)
        browser.display(url, selecting: nil)
        refreshChrome()
        onChange?(self)
    }

    /// Re-reads what the pane shows. `changedFolders` (see `FileBrowser.reload`) limits
    /// the work to those folders; nil re-reads everything.
    func reload(changedFolders: Set<String>? = nil) {
        let folderBefore = currentDirectory
        let shownBefore = shownDirectories
        browser.reload(options: env.preferences.listingOptions(sort: sort, filter: filter), changedFolders: changedFolders)
        refreshChrome()
        if currentDirectory.standardizedFileURL.path != folderBefore.standardizedFileURL.path {
            // The folder the pane was in is gone (deleted outside the app) and Columns
            // view fell back to a folder above it: the pane is there now. Back shouldn't
            // lead to the folder that no longer exists.
            history.replaceCurrent(with: currentDirectory)
            onChange?(self)
        } else if shownDirectories != shownBefore {
            // Columns came or went: other folders are on screen (and to be watched).
            onChange?(self)
        }
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
            // The full path, all selected: ready to copy or to type over.
            header.beginPathEditing(currentDirectory.path, selectAll: true)
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
        // While results are shown the field is the search field: ⌘F edits the search.
        guard searchQuery == nil else { return beginSearch() }
        activate(focus: false)
        header.beginFilter()
    }

    func setFilter(_ text: String) {
        filter = text
        reload()
        if let first = browser.visibleItems.first, browser.selectedItems.isEmpty { browser.select([first.url]) }
    }

    /// Typing in the file list: `text` goes at the end of the filter; focus stays in the list.
    func typeIntoFilter(_ text: String) {
        header.showFilter(filter + text)
        setFilter(filter + text)
    }

    /// Backspace in the file list; removing the last character removes the filter.
    func deleteFilterCharacter() {
        let shorter = String(filter.dropLast())
        if shorter.isEmpty {
            clearFilter()
        } else {
            header.showFilter(shorter)
            setFilter(shorter)
        }
    }

    func clearFilter(reload doReload: Bool = true) {
        header.clearFilter()
        guard !filter.isEmpty else { return }
        filter = ""
        if doReload { reload() }
    }

    /// Files changed (FSEvents, an operation, undo); `changedFolders` when it is known
    /// which. While a rename is being typed the reload waits; ending the edit early
    /// would commit a half-typed name.
    func reloadForExternalChange(in changedFolders: Set<String>? = nil) {
        guard !InlineRenamer.isEditing else {
            reloadPendingAfterRename = true
            return
        }
        // A reload that waited for a rename could be about any folder: read them all.
        let postponed = reloadPendingAfterRename
        reloadPendingAfterRename = false
        reload(changedFolders: postponed ? nil : changedFolders)
    }

    /// A rename ended, in this pane or another one: catch up on a reload that waited.
    func reloadIfPostponed() {
        guard reloadPendingAfterRename, !InlineRenamer.isEditing else { return }
        reloadPendingAfterRename = false
        reload()
    }

    func focus() { browser.focus() }

    func activate(focus: Bool) {
        onActivate?(self)
        if focus { browser.focus() }
    }

    private func goBack() {
        endSearch()
        guard let url = history.goBack() else { return }
        let from = currentDirectory
        browser.display(url, selecting: from.deletingLastPathComponent() == url ? from : nil)
        refreshChrome()
        onChange?(self)
    }

    private func goForward() {
        endSearch()
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
        // Archives Drevo can expand itself: Archive Utility would reveal the result in a
        // new Finder window.
        let archives = files.filter { ArchiveExtraction.format(of: $0.url) != nil }
        let others = files.filter { ArchiveExtraction.format(of: $0.url) == nil }
        if !archives.isEmpty {
            operations.extract(archives.map(\.url), window: view.window) { [weak self] outputs in
                self?.reload(selectingResults: outputs)
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
        case .enclosingFolder:
            // From a search result: the folder it is in, with it selected.
            if searchQuery != nil, selectedItems.count == 1, let item = selectedItems.first {
                navigate(to: item.url.deletingLastPathComponent(), selecting: item.url)
            } else {
                goToEnclosingFolder()
            }
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
        case .search: beginSearch()
        case .sortByName: chooseSort(.name)
        case .sortByKind: chooseSort(.kind)
        case .sortByModified: chooseSort(.modified)
        case .sortByCreated: chooseSort(.created)
        case .sortBySize: chooseSort(.size)
        case .reverseSort: reverseSort()
        case .newTab: newTab()
        case .closeTab: if !closeTab(at: activeTabIndex) { view.window?.performClose(nil) }
        case .nextTab: selectTab((activeTabIndex + 1) % tabCount)
        case .previousTab: selectTab((activeTabIndex - 1 + tabCount) % tabCount)
        default: return performFileCommand(id)
        }
        return true
    }

    static func userFolder(_ d: FileManager.SearchPathDirectory) -> URL {
        FileManager.default.urls(for: d, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// The key bindings changed: refresh what names them.
    func keyMapChanged() {
        sortButton.showShortcuts(env.keyMap)
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
        let all = tabs
        tabBar.show(titles: all.map { Formatting.displayName($0.directory) }, tooltips: all.map(\.directory.path), active: activeTabIndex)
        tabBar.isHidden = all.count < 2
        tabBarHeight.constant = all.count < 2 ? 0 : PaneTabBar.height
        updateStatus()
    }

    private func updateStatus() {
        statusBar.update(items: browser.visibleItems, selected: browser.selectedItems, directory: currentDirectory)
        if !filter.isEmpty { statusBar.left.stringValue = "Filter “\(filter)”: " + statusBar.left.stringValue }
        if let searchQuery, let results = searchResults {
            var text = "Search “\(searchQuery)”: " + statusBar.left.stringValue
            if results.isSearching { text += " · searching…" }
            if results.isTruncated { text += " · stopped at the first \(browser.visibleItems.count)" }
            statusBar.left.stringValue = text
        }
    }

    // MARK: FileBrowserDelegate

    func browser(_ browser: FileBrowser, didMoveTo directory: URL) {
        // A filter belongs to the folder it was typed in.
        if !filter.isEmpty || header.isFiltering { clearFilter() }
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
        if event.keyCode == 53, searchQuery != nil { // Esc leaves the search results
            endSearch()
            return true
        }
        guard let id = env.keyMap.command(for: event) else { return handleFilterTyping(event) }
        // Arrow keys fall through to the table when the command has nothing to do.
        if id == .levelDown { return perform(.levelDown) }
        return dispatcher?.perform(id) ?? perform(id)
    }

    /// Keys no command claims: printable characters extend the filter, Backspace shortens it.
    private func handleFilterTyping(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control])
        // Results aren't filtered by typing: the field above them holds the search.
        guard searchQuery == nil, mods.isEmpty, let chars = event.characters, !chars.isEmpty else { return false }
        if event.keyCode == 51 { // Backspace
            guard !filter.isEmpty else { return false }
            deleteFilterCharacter()
            return true
        }
        let printable = chars.unicodeScalars.allSatisfy { s in
            !CharacterSet.controlCharacters.contains(s) && !(0xF700...0xF8FF).contains(s.value) // function keys
        }
        guard printable else { return false }
        typeIntoFilter(chars)
        return true
    }

    func browser(_ browser: FileBrowser, open items: [FileItem]) {
        open(items)
    }

    func browser(_ browser: FileBrowser, drop urls: [URL], onto destination: URL, kind: TransferKind) {
        activate(focus: true)
        operations.transfer(kind, urls, to: destination, window: view.window) { [weak self] result in
            guard let self else { return }
            if FileIdentity.sameItem(destination, self.currentDirectory) {
                self.reload(selectingResults: result.outputs)
            }
        }
    }

    func browserDragEnded(_ browser: FileBrowser) {
        // Items dragged to another app may have moved out of this folder.
        reload()
    }
}
