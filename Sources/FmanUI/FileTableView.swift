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
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        var rows = selectedRowIndexes
        if row >= 0, !rows.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            rows = IndexSet(integer: row)
        } else if row < 0 {
            rows = []
        }
        window?.makeFirstResponder(self)
        return menuProvider?(rows)
    }

    /// The row the keyboard cursor is on: last selected row.
    var cursorRow: Int {
        selectedRowIndexes.last ?? -1
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
