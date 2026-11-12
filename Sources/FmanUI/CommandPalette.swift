import AppKit
import FmanCore

/// A panel that can become key without a title bar.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// ⇧⌘P: fuzzy-search every command, see its shortcut, run it with Return.
@MainActor
final class CommandPalette: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    private(set) static var current: CommandPalette?

    let panel: KeyablePanel
    let field = NSTextField()
    let table = NSTableView()
    private weak var host: MainWindowController?
    private(set) var results: [CommandSpec] = []

    static func show(for host: MainWindowController) {
        current?.close()
        let p = CommandPalette(host: host)
        current = p
        p.present()
    }

    private init(host: MainWindowController) {
        self.host = host
        panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                             styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.isMovable = false
        panel.hidesOnDeactivate = true
        panel.delegate = self
        panel.isReleasedWhenClosed = false

        field.placeholderString = "Type a command…"
        field.font = .systemFont(ofSize: 16)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 28
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(runSelected)
        table.refusesFirstResponder = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        let sep = NSBox()
        sep.boxType = .separator
        for v in [field, sep, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(v)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            sep.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            sep.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6),
        ])
        panel.contentView = background
        update(query: "")
    }

    private func present() {
        if let hostWindow = host?.window {
            let f = hostWindow.frame
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - 90))
            hostWindow.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if CommandPalette.current === self { CommandPalette.current = nil }
    }

    // MARK: Search

    func update(query: String) {
        let specs = CommandRegistry.all
        results = query.isEmpty ? specs : FuzzyMatch.rank(query, specs) { "\($0.title) \($0.category.rawValue)" }.map(\.item)
        table.reloadData()
        if let first = results.indices.first(where: { isEnabled(results[$0]) }) ?? results.indices.first {
            table.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
            table.scrollRowToVisible(first)
        }
    }

    private func isEnabled(_ spec: CommandSpec) -> Bool {
        guard let host else { return false }
        return spec.isStandardEdit || host.canPerform(spec.id)
    }

    func controlTextDidChange(_ obj: Notification) {
        update(query: field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): runSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); host?.paneGroup.activePane.focus(); return true
        default: return false
        }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let row = max(0, min(results.count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc func runSelected() {
        let row = table.selectedRow
        guard row >= 0, row < results.count, let host else { return }
        let spec = results[row]
        guard isEnabled(spec) else { NSSound.beep(); return }
        close()
        host.window?.makeKeyAndOrderFront(nil)
        host.paneGroup.activePane.focus()
        if spec.isStandardEdit {
            NSApp.sendAction(Self.selector(for: spec.id), to: nil, from: nil)
        } else {
            host.perform(spec.id)
        }
    }

    private static func selector(for id: CommandID) -> Selector {
        switch id {
        case .copy: return #selector(NSText.copy(_:))
        case .cut: return #selector(NSText.cut(_:))
        case .paste: return #selector(NSText.paste(_:))
        case .selectAll: return #selector(NSText.selectAll(_:))
        case .undo: return #selector(UndoActions.undo(_:))
        default: return #selector(UndoActions.redo(_:))
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let spec = results[row]
        let title = NSTextField(labelWithString: spec.title)
        title.font = .systemFont(ofSize: 13)
        let category = NSTextField(labelWithString: spec.category.rawValue)
        category.font = .systemFont(ofSize: 11)
        category.textColor = .tertiaryLabelColor
        let keys = NSStackView()
        keys.spacing = 4
        for combo in (host?.env.keyMap.keys(for: spec.id) ?? []).prefix(2) {
            keys.addArrangedSubview(KeycapView(combo.description, small: true))
        }
        let left = NSStackView(views: [title, category])
        left.spacing = 8
        let cell = NSTableCellView()
        for v in [left, keys] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            left.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            keys.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            keys.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            left.trailingAnchor.constraint(lessThanOrEqualTo: keys.leadingAnchor, constant: -8),
        ])
        cell.alphaValue = isEnabled(spec) ? 1 : 0.4
        cell.toolTip = spec.help.isEmpty ? nil : spec.help
        return cell
    }
}

/// Help ▸ Keyboard Shortcuts: every command and its keys, grouped.
@MainActor
enum ShortcutsWindow {
    private static var window: NSWindow?

    static func text(keyMap: KeyMap) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: 260)]
        para.paragraphSpacing = 2
        for category in CommandCategory.allCases {
            let specs = CommandRegistry.all.filter { $0.category == category }
            guard !specs.isEmpty else { continue }
            out.append(NSAttributedString(string: (out.length == 0 ? "" : "\n") + category.rawValue + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor,
            ]))
            for spec in specs {
                let keys = keyMap.keys(for: spec.id).map(\.description).joined(separator: "   ")
                out.append(NSAttributedString(string: "\(spec.title)\t\(keys.isEmpty ? "—" : keys)\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: para,
                ]))
            }
        }
        out.append(NSAttributedString(string: "\nAlso: type to jump to a name · / or ~ edits the path · Esc clears a filter\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return out
    }

    static func show(keyMap: KeyMap) {
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Keyboard Shortcuts"
            w.isReleasedWhenClosed = false
            let scroll = NSTextView.scrollableTextView()
            (scroll.documentView as? NSTextView)?.isEditable = false
            (scroll.documentView as? NSTextView)?.textContainerInset = NSSize(width: 16, height: 16)
            w.contentView = scroll
            w.center()
            window = w
            return w
        }()
        ((w.contentView as? NSScrollView)?.documentView as? NSTextView)?.textStorage?.setAttributedString(text(keyMap: keyMap))
        w.makeKeyAndOrderFront(nil)
    }
}
