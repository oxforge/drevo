import AppKit
import FmanCore

/// List view (Midnight Commander style): one sortable table for the current folder.
@MainActor
final class FileListViewController: NSViewController, FileBrowser, NSTableViewDataSource, NSTableViewDelegate {
    weak var delegate: FileBrowserDelegate?
    private let preferences: Preferences
    private(set) var currentDirectory: URL
    private(set) var visibleItems: [FileItem] = []
    private var options: ListingOptions
    private var rowSize: RowSize
    private(set) var loadError: Error?

    let tableView = FileTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")

    private enum Column: String, CaseIterable {
        case name, modified, size, kind
        var title: String { ["Name", "Date Modified", "Size", "Kind"][Column.allCases.firstIndex(of: self)!] }
        var sortKey: SortKey { [.name, .modified, .size, .kind][Column.allCases.firstIndex(of: self)!] }
    }

    init(directory: URL, options: ListingOptions, preferences: Preferences) {
        self.currentDirectory = directory
        self.options = options
        self.preferences = preferences
        self.rowSize = preferences.rowSize
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.intercellSpacing = NSSize(width: 6, height: 0)
        tableView.rowHeight = rowSize.rowHeight
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked(_:))
        tableView.allowsTypeSelect = true

        for col in Column.allCases {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.rawValue))
            c.title = col.title
            c.sortDescriptorPrototype = NSSortDescriptor(key: col.rawValue, ascending: true)
            switch col {
            case .name: c.width = 260; c.minWidth = 120; c.resizingMask = [.autoresizingMask, .userResizingMask]
            case .modified: c.width = 150; c.minWidth = 80
            case .size: c.width = 70; c.minWidth = 50; c.headerCell.alignment = .right
            case .kind: c.width = 110; c.minWidth = 60
            }
            tableView.addTableColumn(c)
        }
        applySortIndicator()

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
            let items = rows.compactMap { $0 < self.visibleItems.count ? self.visibleItems[$0] : nil }
            return self.delegate?.browser(self, menuFor: items)
        }

        FileDragDrop.configure(tableView)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

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
        load(selecting: nil)
    }

    // MARK: FileBrowser

    var selectedItems: [FileItem] {
        tableView.selectedRowIndexes.compactMap { $0 < visibleItems.count ? visibleItems[$0] : nil }
    }

    var hasFocus: Bool { view.window?.firstResponder === tableView }
    var activeTableView: FileTableView? { tableView }

    func display(_ directory: URL, selecting: URL?) {
        currentDirectory = directory
        _ = view
        load(selecting: selecting)
        tableView.scrollRowToVisible(max(0, tableView.selectedRow))
    }

    func reload(options newOptions: ListingOptions) {
        options = newOptions
        _ = view
        let selected = selectedItems.map(\.url)
        let cursor = tableView.cursorRow >= 0 && tableView.cursorRow < visibleItems.count ? visibleItems[tableView.cursorRow].url : nil
        let visibleRect = scrollView.contentView.bounds
        load(selecting: nil)
        select(selected)
        if selectedItems.isEmpty, let cursor, let i = visibleItems.firstIndex(where: { $0.url == cursor }) {
            tableView.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        }
        scrollView.contentView.scroll(to: visibleRect.origin)
    }

    func select(_ urls: [URL]) {
        let wanted = Set(urls.map(\.standardizedFileURL))
        let rows = IndexSet(visibleItems.indices.filter { wanted.contains(visibleItems[$0].url.standardizedFileURL) })
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { tableView.scrollRowToVisible(first) }
    }

    func focus() {
        view.window?.makeFirstResponder(tableView)
    }

    func levelUp() -> Bool { false }

    func levelDown() -> Bool {
        guard let item = cursorItem, item.isContainer else { return false }
        display(item.url, selecting: nil)
        delegate?.browser(self, didMoveTo: item.url)
        return true
    }

    func applyRowSize(_ size: RowSize) {
        rowSize = size
        tableView.rowHeight = size.rowHeight
        tableView.reloadData()
    }

    var cursorItem: FileItem? {
        let r = tableView.cursorRow
        return r >= 0 && r < visibleItems.count ? visibleItems[r] : nil
    }

    // MARK: Loading

    private func load(selecting: URL?) {
        do {
            visibleItems = try DirectoryListing.load(currentDirectory, options: options)
            loadError = nil
        } catch {
            visibleItems = []
            loadError = error
        }
        tableView.reloadData()
        updateEmptyState()
        if let selecting, let i = visibleItems.firstIndex(where: { $0.url.standardizedFileURL == selecting.standardizedFileURL }) {
            tableView.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
            tableView.scrollRowToVisible(i)
        } else if !visibleItems.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    private func updateEmptyState() {
        if let loadError {
            emptyLabel.stringValue = BrowserMessages.loadFailure(loadError, folder: currentDirectory)
            emptyLabel.isHidden = false
        } else if visibleItems.isEmpty {
            emptyLabel.stringValue = options.filter.isEmpty ? "Empty folder" : "No matches for “\(options.filter)”"
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }
    }

    private func applySortIndicator() {
        let key: Column = Column.allCases.first { $0.sortKey == options.sort.key } ?? .name
        tableView.sortDescriptors = [NSSortDescriptor(key: key.rawValue, ascending: options.sort.ascending)]
    }

    var sortOrder: FileSort { options.sort }
    var onSortChange: ((FileSort) -> Void)?

    // MARK: Actions

    @objc private func doubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < visibleItems.count else { return }
        delegate?.browser(self, open: visibleItems[row])
    }

    // MARK: Data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { visibleItems.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        FileRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let col = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let item = visibleItems[row]
        let id = NSUserInterfaceItemIdentifier("cell.\(col.rawValue)")
        switch col {
        case .name:
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NameCellView ?? {
                let c = NameCellView(frame: .zero); c.identifier = id; return c
            }()
            cell.configure(item, size: rowSize, showExtension: preferences.showAllExtensions)
            return cell
        case .modified, .size, .kind:
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? TextCellView ?? {
                let c = TextCellView(alignment: col == .size ? .right : .left); c.identifier = id; return c
            }()
            let text: String
            switch col {
            case .modified: text = Formatting.date(item.modified, relative: preferences.relativeDates)
            case .size: text = Formatting.size(item.size)
            default: text = item.kind
            }
            cell.configure(text, size: rowSize, monospacedDigits: col != .kind, dimmed: item.isHidden)
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        delegate?.browserSelectionDidChange(self)
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let key = d.key, let col = Column(rawValue: key) else { return }
        var sort = options.sort
        sort.key = col.sortKey
        sort.ascending = d.ascending
        options.sort = sort
        reload(options: options)
        onSortChange?(sort)
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        tableColumn?.identifier.rawValue == Column.name.rawValue ? visibleItems[row].name : nil
    }

    // MARK: Drag & drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        row < visibleItems.count ? FileDragDrop.writer(for: visibleItems[row]) : nil
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        FileDragDrop.validate(tableView, info: info, row: row, operation: op, items: visibleItems, directory: currentDirectory)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        let urls = FileDragDrop.fileURLs(info)
        let dest = FileDragDrop.destination(row: row, operation: op, items: visibleItems, directory: currentDirectory)
        guard !urls.isEmpty else { return false }
        delegate?.browser(self, drop: urls, onto: dest, kind: FileDragDrop.kind(info, sources: urls, destination: dest))
        return true
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        delegate?.browserDragEnded(self)
    }
}

enum BrowserMessages {
    static func loadFailure(_ error: Error, folder: URL) -> String {
        let ns = error as NSError
        let name = folder.lastPathComponent.isEmpty ? folder.path : folder.lastPathComponent
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError {
            return "fman doesn’t have permission to see “\(name)”.\nGrant access in System Settings ▸ Privacy & Security ▸ Files and Folders (or Full Disk Access)."
        }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError {
            return "“\(name)” no longer exists."
        }
        return "Can’t open “\(name)”: \(ns.localizedDescription)"
    }
}
