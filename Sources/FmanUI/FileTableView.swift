import AppKit
import FmanCore

/// Table used by both views: routes keys through the keymap before NSTableView's own
/// handling (arrows, type-select), and reports focus so the owning pane becomes active.
@MainActor
final class FileTableView: NSTableView {
    /// Return true if the key ran a command.
    var keyHandler: ((NSEvent) -> Bool)?
    var onFocus: (() -> Void)?
    var menuProvider: ((IndexSet) -> NSMenu?)?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        if handlePagingKey(event) { return }
        super.keyDown(with: event)
    }

    // MARK: Paging

    /// The end of the selection that keyboard paging moves (the other end is the anchor).
    private var pagingLead: Int?

    private enum KeyCode {
        static let pageUp: UInt16 = 116, pageDown: UInt16 = 121, home: UInt16 = 115, end: UInt16 = 119
    }

    /// Page Up/Down (fn+↑/↓) and Home/End (fn+←/→) move the selection like a commander's
    /// cursor instead of only scrolling (AppKit's default); with ⇧ they extend it.
    private func handlePagingKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.shift, .command, .option, .control])
        guard mods.isEmpty || mods == .shift, numberOfRows > 0 else { return false }
        let delta: Int
        switch event.keyCode {
        case KeyCode.pageDown: delta = rowsPerPage
        case KeyCode.pageUp: delta = -rowsPerPage
        case KeyCode.end: delta = numberOfRows
        case KeyCode.home: delta = -numberOfRows
        default: return false
        }
        moveSelection(by: delta, extending: mods == .shift)
        return true
    }

    /// Rows that fit in the visible area, less one so the old cursor row stays in view.
    var rowsPerPage: Int {
        let pitch = rowHeight + intercellSpacing.height
        guard pitch > 0 else { return 1 }
        return max(1, Int(visibleRect.height / pitch) - 1)
    }

    /// Moves the cursor `delta` rows (clamped); `extending` selects from the anchor to it.
    func moveSelection(by delta: Int, extending: Bool) {
        let selection = selectedRowIndexes
        let lead = pagingLead.flatMap { selection.contains($0) ? $0 : nil } ?? selection.last ?? (delta > 0 ? -1 : numberOfRows)
        let target = max(0, min(numberOfRows - 1, lead + delta))
        if extending, let first = selection.first, let last = selection.last {
            let anchor = lead == first ? last : first
            selectRowIndexes(IndexSet(integersIn: min(anchor, target)...max(anchor, target)), byExtendingSelection: false)
        } else {
            selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        }
        pagingLead = target
        scrollRowToVisible(target)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        // Focus first: in Columns view, focusing tells the browser which column is current
        // before the selection change rebuilds the columns after it.
        window?.makeFirstResponder(self)
        var rows = selectedRowIndexes
        if row >= 0, !rows.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            rows = IndexSet(integer: row)
        } else if row < 0 {
            rows = []
        }
        return menuProvider?(rows)
    }

    /// The row the keyboard cursor is on: where paging left it, else the last selected row.
    var cursorRow: Int {
        if let lead = pagingLead, selectedRowIndexes.contains(lead) { return lead }
        return selectedRowIndexes.last ?? -1
    }
}

/// Row view; NSTableView already greys the selection of a table that isn't first
/// responder, which is how the inactive pane reads as inactive.
final class FileRowView: NSTableRowView {}

/// A cell whose name can be edited in place.
@MainActor
protocol NameEditingCell: NSView {
    var nameLabel: NSTextField { get }
}

/// Cell for the Name column: icon + name.
final class NameCellView: NSTableCellView, NameEditingCell {
    var nameLabel: NSTextField { label }
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        label.isEditable = false
        imageView = icon
        textField = label
        for v in [icon, label] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        iconWidth = icon.widthAnchor.constraint(equalToConstant: 16)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidth,
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private var iconWidth: NSLayoutConstraint!

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: FileItem, size: RowSize, showExtension: Bool) {
        icon.image = FileIcons.shared.icon(for: item.url)
        iconWidth.constant = size.iconSize
        label.stringValue = showExtension ? item.name : displayName(item)
        label.font = .systemFont(ofSize: size.fontSize)
        alphaValue = item.isHidden ? 0.5 : 1
        toolTip = item.name
    }

    private func displayName(_ item: FileItem) -> String {
        (try? item.url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? item.name
    }
}

/// Plain right- or left-aligned text cell (date, size, kind).
final class TextCellView: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    init(alignment: NSTextAlignment) {
        super.init(frame: .zero)
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .secondaryLabelColor
        textField = label
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: String, size: RowSize, monospacedDigits: Bool, dimmed: Bool) {
        label.stringValue = text
        label.font = monospacedDigits
            ? .monospacedDigitSystemFont(ofSize: size.fontSize - 1, weight: .regular)
            : .systemFont(ofSize: size.fontSize - 1)
        alphaValue = dimmed ? 0.5 : 1
    }
}
