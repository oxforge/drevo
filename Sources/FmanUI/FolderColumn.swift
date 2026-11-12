import AppKit
import FmanCore

/// One column: a folder's contents in a single-column table.
@MainActor
final class FolderColumn: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let directory: URL
    private(set) var items: [FileItem] = []
    private(set) var loadError: Error?
    var index = 0
    var onSelectionChange: (() -> Void)?
    var onFocus: (() -> Void)?
    var keyHandler: ((NSEvent) -> Bool)?
    var onDoubleClick: (([FileItem]) -> Void)?
    var menuProvider: (([FileItem]) -> NSMenu?)?
    var onDrop: (([URL], URL, TransferKind) -> Void)?
    var onDragEnded: (() -> Void)?

    let tableView = FileTableView()
    let container = NSView()
    private let scrollView = NSScrollView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let preferences: Preferences
    private var rowSize: RowSize
    private var suppressNotify = false

    init(directory: URL, options: ListingOptions, preferences: Preferences, rowSize: RowSize) {
        self.directory = directory
        self.preferences = preferences
        self.rowSize = rowSize
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.allowsMultipleSelection = true
        tableView.allowsTypeSelect = true
        tableView.rowHeight = rowSize.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked(_:))
        tableView.onFocus = { [weak self] in self?.onFocus?() }
        tableView.keyHandler = { [weak self] e in self?.keyHandler?(e) ?? false }
        tableView.menuProvider = { [weak self] rows in
            guard let self else { return nil }
            return self.menuProvider?(rows.compactMap { $0 < self.items.count ? self.items[$0] : nil })
        }

        FileDragDrop.configure(tableView)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        message.textColor = .tertiaryLabelColor
        message.alignment = .center
        message.font = .systemFont(ofSize: 11)
        message.isHidden = true

        let divider = NSBox()
        divider.boxType = .separator
        for v in [scrollView, message, divider] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: divider.leadingAnchor),
            divider.topAnchor.constraint(equalTo: container.topAnchor),
            divider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            message.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            message.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -24),
        ])
        load(options: options)
    }

    var selectedItems: [FileItem] {
        tableView.selectedRowIndexes.compactMap { $0 < items.count ? items[$0] : nil }
    }

    /// Re-reads the folder, keeping selection and scroll position. With `keepingCursor`,
    /// when none of the selected items are left (moved away, deleted), the row that took
    /// the first one's place gets selected, so the cursor doesn't vanish.
    func reload(options: ListingOptions, keepingCursor: Bool) {
        let selected = selectedItems.map(\.url)
        let firstSelectedRow = tableView.selectedRowIndexes.first
        let origin = scrollView.contentView.bounds.origin
        load(options: options)
        select(selected, notify: false)
        var cursor: Int?
        if keepingCursor, let firstSelectedRow, tableView.selectedRowIndexes.isEmpty, !items.isEmpty {
            cursor = min(firstSelectedRow, items.count - 1)
            select(rows: IndexSet(integer: cursor!), notify: false)
        }
        scrollView.contentView.scroll(to: origin)
        if let cursor { tableView.scrollRowToVisible(cursor) }
    }

    /// How often the folder was read from disk (tests check that a change elsewhere
    /// doesn't re-read this column).
    private(set) var loadCount = 0

    private func load(options: ListingOptions) {
        loadCount += 1
        do {
            items = try DirectoryListing.load(directory, options: options)
            loadError = nil
        } catch {
            items = []
            loadError = error
        }
        suppressNotify = true
        tableView.reloadData()
        suppressNotify = false
        if let loadError {
            message.stringValue = BrowserMessages.loadFailure(loadError, folder: directory)
            message.isHidden = false
        } else if items.isEmpty {
            message.stringValue = options.filter.isEmpty ? "Empty folder" : "No matches"
            message.isHidden = false
        } else {
            message.isHidden = true
        }
    }

    func select(_ urls: [URL], notify: Bool) {
        let wanted = Set(urls.map { $0.standardizedFileURL.path })
        let rows = IndexSet(items.indices.filter { wanted.contains(items[$0].url.standardizedFileURL.path) })
        select(rows: rows, notify: notify)
    }

    func select(rows: IndexSet, notify: Bool) {
        suppressNotify = !notify
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        suppressNotify = false
        if let first = rows.first { tableView.scrollRowToVisible(first) }
    }

    func apply(rowSize: RowSize) {
        self.rowSize = rowSize
        tableView.rowHeight = rowSize.rowHeight
        tableView.reloadData()
    }

    @objc private func doubleClicked(_ sender: Any?) {
        openRow(tableView.clickedRow)
    }

    func openRow(_ row: Int) {
        let chosen = itemsForDoubleClick(row: row, items: items, selection: tableView.selectedRowIndexes)
        if !chosen.isEmpty { onDoubleClick?(chosen) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FileRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("columnCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ColumnCellView ?? {
            let c = ColumnCellView(frame: .zero); c.identifier = id; return c
        }()
        cell.configure(items[row], size: rowSize, showExtension: preferences.showAllExtensions)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !suppressNotify { onSelectionChange?() }
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        items[row].name
    }

    // MARK: Drag & drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        row < items.count ? FileDragDrop.writer(for: items[row]) : nil
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        FileDragDrop.validate(tableView, info: info, row: row, operation: op, items: items, directory: directory)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        let urls = FileDragDrop.fileURLs(info)
        guard !urls.isEmpty else { return false }
        let dest = FileDragDrop.destination(row: row, operation: op, items: items, directory: directory)
        onDrop?(urls, dest, FileDragDrop.kind(info, sources: urls, destination: dest))
        return true
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragEnded?()
    }
}
