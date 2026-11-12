import AppKit
import DrevoCore

/// Edits a file name in place in its table cell. Return/Tab commit, Esc cancels.
/// Selects the name without its extension, like Finder.
@MainActor
final class InlineRenamer: NSObject, NSTextFieldDelegate {
    private let label: NSTextField
    private let table: NSTableView
    private let originalText: String
    private let originalName: String
    private let completion: (String?) -> Void
    private var cancelled = false
    private var finished = false
    private static var active: InlineRenamer?

    private init(label: NSTextField, table: NSTableView, name: String, completion: @escaping (String?) -> Void) {
        self.label = label
        self.table = table
        self.originalText = label.stringValue
        self.originalName = name
        self.completion = completion
    }

    /// Starts editing `row` of `table`; `completion` gets the new name, or nil if cancelled/unchanged.
    @discardableResult
    static func begin(table: NSTableView, row: Int, item: FileItem, completion: @escaping (String?) -> Void) -> Bool {
        guard row >= 0, row < table.numberOfRows else { return false }
        table.scrollRowToVisible(row)
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NameEditingCell else { return false }
        active?.finish(commit: false)
        let r = InlineRenamer(label: cell.nameLabel, table: table, name: item.name, completion: completion)
        active = r
        r.start(selecting: item.baseName)
        return true
    }

    static var isEditing: Bool { active != nil }

    /// Posted when a rename ends, committed or cancelled, after its completion ran.
    /// There is one editor for the whole app, so reloads everywhere wait for it.
    static let didEndEditing = Notification.Name("drevo.renameDidEnd")

    private func start(selecting base: String) {
        label.stringValue = originalName
        label.isEditable = true
        label.isSelectable = true
        label.isBezeled = false
        label.drawsBackground = true
        label.backgroundColor = .textBackgroundColor
        label.textColor = .labelColor
        label.focusRingType = .exterior
        label.delegate = self
        guard table.window?.makeFirstResponder(label) == true, let editor = label.currentEditor() else {
            finish(commit: false)
            return
        }
        let length = (base as NSString).length
        editor.selectedRange = NSRange(location: 0, length: min(length, (originalName as NSString).length))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelled = true
            table.window?.makeFirstResponder(table)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        finish(commit: !cancelled)
    }

    private func finish(commit: Bool) {
        guard !finished else { return }
        finished = true
        let text = label.stringValue
        label.delegate = nil
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.stringValue = originalText
        if Self.active === self { Self.active = nil }
        if table.window?.firstResponder !== table { table.window?.makeFirstResponder(table) }
        completion(commit && text != originalName ? text : nil)
        NotificationCenter.default.post(name: Self.didEndEditing, object: nil)
    }
}
