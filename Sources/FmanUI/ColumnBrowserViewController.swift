import AppKit
import FmanCore
import QuickLookThumbnailing

/// Finder-style Miller columns: one table per folder level plus a preview for a selected file.
@MainActor
final class ColumnBrowserViewController: NSViewController, FileBrowser {
    weak var delegate: FileBrowserDelegate?
    private let preferences: Preferences
    private var options: ListingOptions
    private var rowSize: RowSize

    private(set) var columns: [FolderColumn] = []
    private(set) var focusedIndex = 0
    private var preview: FilePreviewView?

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    static let columnWidth: CGFloat = 230

    init(directory: URL, options: ListingOptions, preferences: Preferences) {
        self.options = options
        self.preferences = preferences
        self.rowSize = preferences.rowSize
        super.init(nibName: nil, bundle: nil)
        pendingDirectory = directory
    }

    private var pendingDirectory: URL?

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .top
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scrollView.documentView = document
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none

        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.widthAnchor.constraint(greaterThanOrEqualTo: clip.widthAnchor),
        ])
        view = scrollView
        if let dir = pendingDirectory {
            pendingDirectory = nil
            display(dir, selecting: nil)
        }
    }

    private var lastWidth: CGFloat = 0

    override func viewDidLayout() {
        super.viewDidLayout()
        if view.bounds.width != lastWidth {
            lastWidth = view.bounds.width
            scrollToFocused()
        }
    }

    // MARK: FileBrowser

    var currentDirectory: URL {
        columns.isEmpty ? (pendingDirectory ?? URL(fileURLWithPath: "/")) : columns[focusedIndex].directory
    }

    var selectedItems: [FileItem] { columns.isEmpty ? [] : columns[focusedIndex].selectedItems }
    var visibleItems: [FileItem] { columns.isEmpty ? [] : columns[focusedIndex].items }
    var activeTableView: FileTableView? { columns.isEmpty ? nil : columns[focusedIndex].tableView }
    var shownDirectories: [URL] { columns.map(\.directory) }

    var hasFocus: Bool {
        guard let fr = view.window?.firstResponder as? NSView else { return false }
        return columns.contains { $0.tableView === fr }
    }

    /// The first column: Home for paths inside Home, else the volume root.
    static func root(for url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let segments = PathBarView.segments(for: url, home: home)
        return segments.first ?? URL(fileURLWithPath: "/")
    }

    func display(_ directory: URL, selecting: URL?) {
        _ = view
        let chain = PathBarView.segments(for: directory)
        rebuild(chain: chain, focusLast: true, selecting: selecting)
    }

    /// Columns for `chain` (root … folder); each column selects the next folder in the chain.
    private func rebuild(chain: [URL], focusLast: Bool, selecting: URL?) {
        let wasFocused = hasFocus
        removeColumns(from: 0)
        for (i, dir) in chain.enumerated() {
            let col = appendColumn(for: dir)
            if i + 1 < chain.count {
                col.select([chain[i + 1]], notify: false)
            }
        }
        focusedIndex = max(0, columns.count - 1)
        let last = columns[focusedIndex]
        if let selecting, last.items.contains(where: { $0.url.standardizedFileURL == selecting.standardizedFileURL }) {
            last.select([selecting], notify: false)
        } else if !last.items.isEmpty {
            last.select(rows: IndexSet(integer: 0), notify: false)
        }
        updateTrailingColumn()
        if wasFocused || focusLast && view.window?.firstResponder == nil { focusColumn(focusedIndex) }
        scrollToFocused()
    }

    func reload(options newOptions: ListingOptions) {
        options = newOptions
        _ = view
        // Re-read every column, keeping each one's selection.
        var keep = 0
        for (i, col) in columns.enumerated() {
            col.reload(options: options)
            keep = i
            // Keep a column while its folder exists, even if a filter or the hidden-files
            // setting hides it in its parent (e.g. a path typed into ~/.config).
            if i + 1 < columns.count {
                var isDir: ObjCBool = false
                let next = columns[i + 1].directory
                if !FileManager.default.fileExists(atPath: next.path, isDirectory: &isDir) || !isDir.boolValue { break }
            }
        }
        if keep + 1 < columns.count { removeColumns(from: keep + 1) }
        focusedIndex = min(focusedIndex, columns.count - 1)
        updateTrailingColumn()
    }

    func select(_ urls: [URL]) {
        guard !columns.isEmpty else { return }
        columns[focusedIndex].select(urls, notify: true)
    }

    func focus() {
        focusColumn(focusedIndex)
    }

    func levelUp() -> Bool {
        guard !columns.isEmpty else { return false }
        if focusedIndex > 0 {
            let leaving = columns[focusedIndex]
            leaving.tableView.deselectAll(nil)
            removeColumns(from: focusedIndex + 1)
            setFocused(focusedIndex - 1)
            return true
        }
        // At the first column: grow the chain upward.
        let root = columns[0].directory.standardizedFileURL
        let parent = root.deletingLastPathComponent()
        guard parent.path != root.path else { return false }
        let chain = [parent] + columns.map(\.directory)
        let focusDepth = focusedIndex
        rebuild(chain: Array(chain.prefix(focusDepth + 2)), focusLast: false, selecting: nil)
        columns[0].select([root], notify: false)
        removeColumns(from: 1)
        updateTrailingColumn()
        setFocused(0)
        return true
    }

    func levelDown() -> Bool {
        guard !columns.isEmpty else { return false }
        let col = columns[focusedIndex]
        guard col.selectedItems.count == 1, let item = col.selectedItems.first, item.isContainer else { return false }
        if focusedIndex + 1 >= columns.count { updateTrailingColumn() }
        guard focusedIndex + 1 < columns.count else { return false }
        let next = columns[focusedIndex + 1]
        if next.selectedItems.isEmpty, !next.items.isEmpty {
            next.select(rows: IndexSet(integer: 0), notify: false)
        }
        setFocused(focusedIndex + 1)
        updateTrailingColumn()
        return true
    }

    func applyRowSize(_ size: RowSize) {
        rowSize = size
        columns.forEach { $0.apply(rowSize: size) }
    }

    // MARK: Columns

    @discardableResult
    private func appendColumn(for directory: URL) -> FolderColumn {
        let col = FolderColumn(directory: directory, options: options, preferences: preferences, rowSize: rowSize)
        col.index = columns.count
        col.onSelectionChange = { [weak self, weak col] in
            guard let self, let col else { return }
            self.columnSelectionChanged(col)
        }
        col.onFocus = { [weak self, weak col] in
            guard let self, let col else { return }
            if col.index != self.focusedIndex { self.setFocused(col.index, makeFirstResponder: false) }
            self.delegate?.browserDidActivate(self)
        }
        col.keyHandler = { [weak self] event in
            guard let self else { return false }
            return self.delegate?.browser(self, handleKey: event) ?? false
        }
        col.onDoubleClick = { [weak self] item in
            guard let self else { return }
            self.delegate?.browser(self, open: item)
        }
        col.menuProvider = { [weak self] items in
            guard let self else { return nil }
            return self.delegate?.browser(self, menuFor: items)
        }
        col.onDrop = { [weak self] urls, dest, kind in
            guard let self else { return }
            self.delegate?.browser(self, drop: urls, onto: dest, kind: kind)
        }
        col.onDragEnded = { [weak self] in
            guard let self else { return }
            self.delegate?.browserDragEnded(self)
        }
        columns.append(col)
        if let preview { stack.removeView(preview); self.preview = nil }
        stack.addArrangedSubview(col.container)
        col.container.widthAnchor.constraint(equalToConstant: Self.columnWidth).isActive = true
        col.container.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor).isActive = true
        return col
    }

    private func removeColumns(from index: Int) {
        if let preview { stack.removeView(preview); self.preview = nil }
        guard index < columns.count else { return }
        for col in columns[index...] {
            stack.removeView(col.container)
        }
        columns.removeSubrange(index...)
    }

    private func columnSelectionChanged(_ col: FolderColumn) {
        if col.index != focusedIndex, col.tableView.window?.firstResponder === col.tableView {
            focusedIndex = col.index
        }
        removeColumns(from: col.index + 1)
        updateTrailingColumn()
        if col.index == focusedIndex {
            delegate?.browserSelectionDidChange(self)
        }
        scrollToFocused()
    }

    /// After the last column: a column for a selected folder, or a preview for a selected file.
    private func updateTrailingColumn() {
        guard let last = columns.last else { return }
        if let preview { stack.removeView(preview); self.preview = nil }
        let selected = last.selectedItems
        guard selected.count == 1, let item = selected.first else { return }
        if item.isContainer {
            appendColumn(for: item.url)
        } else {
            let p = FilePreviewView(item: item, relativeDates: preferences.relativeDates)
            preview = p
            stack.addArrangedSubview(p)
            p.widthAnchor.constraint(equalToConstant: Self.columnWidth + 40).isActive = true
            p.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor).isActive = true
        }
    }

    private func setFocused(_ index: Int, makeFirstResponder: Bool = true) {
        let changed = index != focusedIndex
        focusedIndex = index
        if makeFirstResponder { focusColumn(index) }
        scrollToFocused()
        if changed {
            delegate?.browser(self, didMoveTo: columns[index].directory)
        }
    }

    private func focusColumn(_ index: Int) {
        guard columns.indices.contains(index) else { return }
        view.window?.makeFirstResponder(columns[index].tableView)
    }

    /// Scrolls so the focused column and the one after it (next folder or preview) are in
    /// view. Like Finder, a partly visible column on the left hints at more levels.
    private func scrollToFocused() {
        guard !columns.isEmpty else { return }
        view.layoutSubtreeIfNeeded()
        let views = stack.arrangedSubviews
        guard let focusedView = views.firstIndex(of: columns[focusedIndex].container) else { return }
        let visibleWidth = scrollView.contentView.bounds.width
        let wanted = views[min(views.count - 1, focusedView + 1)].frame.maxX
        let current = scrollView.contentView.bounds.origin.x
        var x = current
        if wanted - x > visibleWidth { x = wanted - visibleWidth }
        if views[focusedView].frame.minX < x { x = views[focusedView].frame.minX }
        let maxX = max(0, (scrollView.documentView?.frame.width ?? 0) - visibleWidth)
        x = min(max(0, x), maxX)
        guard abs(x - current) > 0.5 else { return }
        scrollView.contentView.scroll(to: NSPoint(x: x, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

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
    var onDoubleClick: ((FileItem) -> Void)?
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

    func reload(options: ListingOptions) {
        let selected = selectedItems.map(\.url)
        let origin = scrollView.contentView.bounds.origin
        load(options: options)
        select(selected, notify: false)
        scrollView.contentView.scroll(to: origin)
    }

    private func load(options: ListingOptions) {
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
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        onDoubleClick?(items[row])
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

/// Name cell with a chevron for folders.
final class ColumnCellView: NSTableCellView, NameEditingCell {
    private let name = NameCellView(frame: .zero)
    var nameLabel: NSTextField { name.label }
    private let chevron = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        chevron.contentTintColor = .tertiaryLabelColor
        for v in [name, chevron] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        textField = name.label
        imageView = name.icon
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.topAnchor.constraint(equalTo: topAnchor),
            name.bottomAnchor.constraint(equalTo: bottomAnchor),
            name.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -2),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: FileItem, size: RowSize, showExtension: Bool) {
        name.configure(item, size: size, showExtension: showExtension)
        chevron.isHidden = !item.isContainer
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { chevron.contentTintColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .tertiaryLabelColor }
    }
}

/// Preview column for a selected file: thumbnail and facts.
@MainActor
final class FilePreviewView: NSView {
    let item: FileItem
    private let imageView = NSImageView()

    init(item: FileItem, relativeDates: Bool) {
        self.item = item
        super.init(frame: .zero)
        imageView.image = FileIcons.shared.icon(for: item.url)
        imageView.imageScaling = .scaleProportionallyUpOrDown

        let title = NSTextField(wrappingLabelWithString: item.name)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.alignment = .center
        title.maximumNumberOfLines = 3
        let subtitle = NSTextField(labelWithString: [item.kind, item.size.map { Formatting.size($0) }].compactMap { $0 }.joined(separator: " — "))
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center

        let grid = NSGridView(views: [
            [Self.key("Created"), Self.value(Formatting.date(item.created, relative: relativeDates))],
            [Self.key("Modified"), Self.value(Formatting.date(item.modified, relative: relativeDates))],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 4
        grid.columnSpacing = 8

        let stack = NSStackView(views: [imageView, title, subtitle, grid])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(16, after: imageView)
        stack.setCustomSpacing(16, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            imageView.widthAnchor.constraint(equalToConstant: 128),
            imageView.heightAnchor.constraint(equalToConstant: 128),
            title.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
        loadThumbnail()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func key(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        return l
    }

    private static func value(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11)
        return l
    }

    private func loadThumbnail() {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 128, height: 128), scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let rep else { return }
            let image = rep.nsImage
            DispatchQueue.main.async { self?.imageView.image = image }
        }
    }
}

/// Document view with a top-left origin so columns hang from the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
