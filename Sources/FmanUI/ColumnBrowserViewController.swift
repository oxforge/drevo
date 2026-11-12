import AppKit
import FmanCore

/// Finder-style Miller columns: one table per folder level plus a preview for a selected file.
@MainActor
final class ColumnBrowserViewController: NSViewController, FileBrowser {
    weak var delegate: FileBrowserDelegate?
    private let preferences: Preferences
    /// The pane's options; their filter applies to the focused column only
    /// (`options(forColumn:)`).
    private var options: ListingOptions
    private var rowSize: RowSize

    private(set) var columns: [FolderColumn] = []
    private(set) var focusedIndex = 0
    private(set) var preview: FilePreviewView?

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

    func display(_ directory: URL, selecting: URL?) {
        _ = view
        // A filter belongs to the folder it was typed in.
        options.filter = ""
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

    func reload(options newOptions: ListingOptions, changedFolders: Set<String>?) {
        // Only the same view of the folders can be refreshed in part.
        let changed = newOptions == options ? changedFolders : nil
        // A new filter starts over at its first match (the pane selects it).
        let sameFilter = newOptions.filter == options.filter
        options = newOptions
        _ = view
        // Re-read the columns (all, or the ones whose folder changed), keeping each
        // one's selection.
        var keep = 0
        var reloadedLast = false
        for (i, col) in columns.enumerated() {
            keep = i
            // Keep a column while its folder exists, even if a filter or the hidden-files
            // setting hides it in its parent (e.g. a path typed into ~/.config).
            let nextIsGone = i + 1 < columns.count && !columns[i + 1].directory.isDirectoryOnDisk
            let isLast = i + 1 == columns.count || nextIsGone
            let folderChanged = changed.map { $0.contains(DirectoryWatcher.normalize(col.directory.path)) } ?? true
            if folderChanged || nextIsGone {
                // Only the last column may move its cursor to a neighbour: in the others
                // the next column still shows what was selected.
                col.reload(options: options(forColumn: i), keepingCursor: isLast && sameFilter)
                reloadedLast = isLast
            }
            if nextIsGone { break }
        }
        if keep + 1 < columns.count { removeColumns(from: keep + 1) }
        focusedIndex = min(focusedIndex, columns.count - 1)
        // What follows the last column depends on that column only.
        if reloadedLast { updateTrailingColumn() }
    }

    /// The filter narrows the column being worked in; the folders leading to it stay whole.
    private func options(forColumn index: Int) -> ListingOptions {
        guard index != focusedIndex else { return options }
        var o = options
        o.filter = ""
        return o
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
        // The focused column is still the first one, but it shows another folder now:
        // setFocused only reports a change of column.
        delegate?.browser(self, didMoveTo: columns[0].directory)
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
        // A new column is never the one being filtered: the filter goes away when the
        // focus moves to another column.
        var unfiltered = options
        unfiltered.filter = ""
        let col = FolderColumn(directory: directory, options: unfiltered, preferences: preferences, rowSize: rowSize)
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
        col.onDoubleClick = { [weak self] items in
            guard let self else { return }
            self.delegate?.browser(self, open: items)
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
        // Never point past the last column (a selection change in an earlier column
        // removes the focused one).
        focusedIndex = min(focusedIndex, max(0, columns.count - 1))
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
        guard !selected.isEmpty else { return }
        if selected.count == 1, selected[0].isContainer {
            appendColumn(for: selected[0].url)
        } else {
            // One file: its preview. Several items: a summary in the same place and width,
            // so extending the selection doesn't make the columns jump.
            let p = FilePreviewView(items: selected, relativeDates: preferences.relativeDates)
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
        guard columns.indices.contains(focusedIndex) else { return }
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

/// Document view with a top-left origin so columns hang from the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
