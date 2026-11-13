import AppKit
import DrevoCore

/// What a search found below a folder, as one list with each item's location. It stands
/// in for the pane's browser while a search is shown, so every file command works on
/// the results as it does on a folder's items.
@MainActor
final class SearchResultsViewController: NSViewController, FileBrowser, NSTableViewDataSource, NSTableViewDelegate {
    weak var delegate: FileBrowserDelegate?
    /// The folder searched; also where new items and pastes go.
    let root: URL
    let query: String
    /// The search is still looking.
    private(set) var isSearching = false
    /// The search stopped at `FileSearch.limit` results.
    private(set) var isTruncated = false
    /// Results arrived or the search ended (the pane's status line follows it).
    var onProgress: (() -> Void)?
    /// Tests search inline, so results are there when `start()` returns.
    var runsSynchronously = false
    var spotlight: FileSearch.SpotlightSource?

    /// Everything found, in the order it was found.
    private var results: [FileItem] = []
    private(set) var visibleItems: [FileItem] = []
    private var options: ListingOptions
    private let preferences: Preferences
    private var rowSize: RowSize
    private var token: CancellationToken?

    let tableView = FileTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")

    private enum Column: String, CaseIterable {
        case name, location, modified, size
        var title: String { ["Name", "Location", "Date Modified", "Size"][Column.allCases.firstIndex(of: self)!] }
    }

    init(root: URL, query: String, options: ListingOptions, preferences: Preferences) {
        self.root = root
        self.query = query
        self.options = options
        self.preferences = preferences
        self.rowSize = preferences.rowSize
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { token?.cancel() }

    override func loadView() {
        tableView.style = .inset
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.intercellSpacing = NSSize(width: 6, height: 0)
        tableView.rowHeight = rowSize.rowHeight
        tableView.allowsTypeSelect = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked(_:))
        for col in Column.allCases {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.rawValue))
            c.title = col.title
            switch col {
            case .name: c.width = 220; c.minWidth = 120; c.resizingMask = [.autoresizingMask, .userResizingMask]
            case .location: c.width = 200; c.minWidth = 80
            case .modified: c.width = 140; c.minWidth = 80
            case .size: c.width = 70; c.minWidth = 50; c.headerCell.alignment = .right
            }
            tableView.addTableColumn(c)
        }
        tableView.keyHandler = { [weak self] event in
            guard let self else { return false }
            return self.delegate?.browser(self, handleKey: event) ?? false
        }
        tableView.onFocus = { [weak self] in
            guard let self else { return }
            self.delegate?.browserDidActivate(self)
        }
        tableView.menuProvider = { [weak self] rows in
            guard let self else { return nil }
            return self.delegate?.browser(self, menuFor: rows.compactMap { $0 < self.visibleItems.count ? self.visibleItems[$0] : nil })
        }
        // Results can be dragged out; nothing can be dropped "into a search".
        FileDragDrop.configure(tableView)
        tableView.unregisterDraggedTypes()

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center

        let container = NSView()
        for v in [scrollView, emptyLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
        ])
        view = container
        refresh()
    }

    // MARK: Searching

    /// Starts looking; results show up as they are found.
    func start() {
        _ = view
        stop()
        let token = CancellationToken()
        self.token = token
        var search = FileSearch(root: root, query: query, showHidden: options.showHidden)
        search.spotlight = spotlight
        isSearching = true
        isTruncated = false
        results = []
        refresh()
        if runsSynchronously {
            let outcome = search.run { self.results += $0 }
            finish(outcome, token)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = search.run(isCancelled: { token.isCancelled }) { batch in
                onMainRunLoop {
                    guard let self, self.token === token else { return }
                    self.results += batch
                    self.refresh()
                }
            }
            onMainRunLoop { self?.finish(outcome, token) }
        }
    }

    func stop() {
        token?.cancel()
        token = nil
        isSearching = false
    }

    private func finish(_ outcome: FileSearch.Outcome, _ token: CancellationToken) {
        guard self.token === token else { return }
        isSearching = false
        isTruncated = outcome.truncated
        refresh()
    }

    /// Sorts what was found by the pane's order and shows it, keeping the selection.
    private func refresh() {
        let selected = selectedItems.map(\.url)
        let hadItems = !visibleItems.isEmpty
        visibleItems = DirectoryListing.apply(options, to: results)
        tableView.reloadData()
        selectRows(for: selected)
        if !hadItems, !visibleItems.isEmpty, tableView.selectedRowIndexes.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        emptyLabel.stringValue = isSearching ? "Searching…" : "Nothing found for “\(query)”"
        emptyLabel.isHidden = !visibleItems.isEmpty
        onProgress?()
    }

    private func selectRows(for urls: [URL]) {
        guard !urls.isEmpty else { return }
        let wanted = Set(urls.map(\.standardizedFileURL))
        let rows = IndexSet(visibleItems.indices.filter { wanted.contains(visibleItems[$0].url.standardizedFileURL) })
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
    }

    /// Where `item` is, relative to the folder searched ("." = right in it).
    func location(of item: FileItem) -> String {
        let folder = item.url.deletingLastPathComponent().standardizedFileURL.path
        let base = root.standardizedFileURL.path
        guard folder.hasPrefix(base) else { return folder }
        let relative = folder.dropFirst(base.count).drop { $0 == "/" }
        return relative.isEmpty ? "." : String(relative)
    }

    // MARK: FileBrowser

    var currentDirectory: URL { root }
    var selectedItems: [FileItem] {
        tableView.selectedRowIndexes.compactMap { $0 < visibleItems.count ? visibleItems[$0] : nil }
    }
    var hasFocus: Bool { view.window?.firstResponder === tableView }
    var activeTableView: FileTableView? { tableView }
    var shownDirectories: [URL] { [root] }

    /// The pane swaps in a folder browser to show a folder; a search shows only results.
    func display(_ directory: URL, selecting: URL?) {}

    /// Files changed: results that are gone leave the list, the others show their
    /// current size and date. The tree isn't searched again.
    func reload(options newOptions: ListingOptions, changedFolders: Set<String>?) {
        options = newOptions
        _ = view
        let firstSelectedRow = tableView.selectedRowIndexes.first
        results = results.compactMap { FileItem.current(at: $0.url) }
        refresh()
        // The selected results are gone (trashed, moved): keep the cursor's place.
        if let firstSelectedRow, tableView.selectedRowIndexes.isEmpty, !visibleItems.isEmpty {
            let row = min(firstSelectedRow, visibleItems.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
    }

    /// Selects `urls`. What an operation just made (a renamed result, a duplicate) joins
    /// the results first when it matches the search, so it doesn't vanish from the list.
    func select(_ urls: [URL]) {
        let known = Set(results.map(\.url.standardizedFileURL))
        let filter = NameFilter(query)
        let rootPath = root.standardizedFileURL.path
        let added = urls.filter { !known.contains($0.standardizedFileURL) }.compactMap { url -> FileItem? in
            guard filter.matches(url.lastPathComponent), url.standardizedFileURL.path.hasPrefix(rootPath + "/") else { return nil }
            return FileItem.current(at: url)
        }
        if !added.isEmpty {
            results += added
            refresh()
        }
        selectRows(for: urls)
        if let first = tableView.selectedRowIndexes.first { tableView.scrollRowToVisible(first) }
    }

    func focus() { view.window?.makeFirstResponder(tableView) }
    /// ← has no meaning in a list of results; it stays put rather than leave the search.
    func levelUp() -> Bool { true }
    func levelDown() -> Bool { false }

    func applyRowSize(_ size: RowSize) {
        rowSize = size
        tableView.rowHeight = size.rowHeight
        tableView.reloadData()
    }

    // MARK: Table

    @objc private func doubleClicked(_ sender: Any?) {
        let items = itemsForDoubleClick(row: tableView.clickedRow, items: visibleItems, selection: tableView.selectedRowIndexes)
        if !items.isEmpty { delegate?.browser(self, open: items) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleItems.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FileRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let col = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let item = visibleItems[row]
        let id = NSUserInterfaceItemIdentifier("search.\(col.rawValue)")
        if col == .name {
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NameCellView ?? {
                let c = NameCellView(frame: .zero); c.identifier = id; return c
            }()
            cell.configure(item, size: rowSize, showExtension: preferences.showAllExtensions)
            return cell
        }
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? TextCellView ?? {
            let c = TextCellView(alignment: col == .size ? .right : .left); c.identifier = id; return c
        }()
        let text: String
        switch col {
        case .location: text = location(of: item)
        case .modified: text = Formatting.date(item.modified, relative: preferences.relativeDates)
        default: text = Formatting.size(item.size)
        }
        cell.configure(text, size: rowSize, monospacedDigits: col != .location, dimmed: col == .location || item.isHidden)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        delegate?.browserSelectionDidChange(self)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        row < visibleItems.count ? FileDragDrop.writer(for: visibleItems[row]) : nil
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        delegate?.browserDragEnded(self)
    }
}
