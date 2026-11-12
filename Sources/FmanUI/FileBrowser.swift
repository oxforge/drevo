import AppKit
import FmanCore

/// Events a browser (List or Columns view) reports to its pane.
@MainActor
protocol FileBrowserDelegate: AnyObject {
    /// The folder the browser considers "current" changed without the pane asking
    /// (Columns view moving focus between columns).
    func browser(_ browser: FileBrowser, didMoveTo directory: URL)
    func browserSelectionDidChange(_ browser: FileBrowser)
    /// The browser's view took keyboard focus or was clicked.
    func browserDidActivate(_ browser: FileBrowser)
    /// A key the browser doesn't handle itself; return true if it ran a command.
    func browser(_ browser: FileBrowser, handleKey event: NSEvent) -> Bool
    /// Double-click: the clicked item, or the whole selection when the click is inside it.
    func browser(_ browser: FileBrowser, open items: [FileItem])
    /// Context menu for the clicked items (empty = folder background).
    func browser(_ browser: FileBrowser, menuFor items: [FileItem]) -> NSMenu?
    /// Files were dropped onto `destination` (a folder row or the shown folder).
    func browser(_ browser: FileBrowser, drop urls: [URL], onto destination: URL, kind: TransferKind)
    /// A drag that started here ended (items may have moved away).
    func browserDragEnded(_ browser: FileBrowser)
}

extension FileBrowserDelegate {
    func browser(_ browser: FileBrowser, menuFor items: [FileItem]) -> NSMenu? { nil }
}

/// A way of showing a folder: List (one table) or Columns (Miller columns).
@MainActor
protocol FileBrowser: AnyObject {
    var view: NSView { get }
    var delegate: FileBrowserDelegate? { get set }
    /// Where new items go and what the path bar shows.
    var currentDirectory: URL { get }
    /// Selected items in the current directory.
    var selectedItems: [FileItem] { get }
    /// Items shown in the current directory (after filtering).
    var visibleItems: [FileItem] { get }
    /// Show `directory`; select `selecting` if it is one of its entries.
    func display(_ directory: URL, selecting: URL?)
    /// Re-read from disk with new options, keeping selection and scroll.
    func reload(options: ListingOptions)
    func select(_ urls: [URL])
    func focus()
    var hasFocus: Bool { get }
    /// ← in this view; false if there is nowhere to go (the pane then goes up a folder).
    func levelUp() -> Bool
    /// → in this view; false if the focused item isn't a folder.
    func levelDown() -> Bool
    func applyRowSize(_ size: RowSize)
    /// The table that hosts the current directory, for editing and drag & drop.
    var activeTableView: FileTableView? { get }
    /// Every folder on screen (all columns), for live watching.
    var shownDirectories: [URL] { get }
}

extension FileBrowser {
    /// Starts in-place renaming of `url` in the current directory.
    @discardableResult
    func beginRename(_ url: URL, completion: @escaping (String?) -> Void) -> Bool {
        let path = url.standardizedFileURL.path
        guard let table = activeTableView,
              let row = visibleItems.firstIndex(where: { $0.url.standardizedFileURL.path == path }) else { return false }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return InlineRenamer.begin(table: table, row: row, item: visibleItems[row], completion: completion)
    }
}

/// What a double-click on `row` opens: a folder opens alone; a file opens together with
/// the rest of the selection when it's part of it (Finder's behaviour).
@MainActor
func itemsForDoubleClick(row: Int, items: [FileItem], selection: IndexSet) -> [FileItem] {
    guard row >= 0, row < items.count else { return [] }
    let clicked = items[row]
    if clicked.isContainer || !selection.contains(row) { return [clicked] }
    return selection.compactMap { $0 < items.count ? items[$0] : nil }.filter { !$0.isContainer }
}
