import AppKit
import FmanCore

/// The mc-style command line under the panes: runs in the active pane's folder.
/// Return runs here, ⌘Return in the terminal app, ⌥Return inserts selected names,
/// ↑/↓ walk history, Esc goes back to the pane.
@MainActor
final class CommandBar: NSView, NSTextFieldDelegate {
    let field = FocusReportingTextField()
    /// The command line got keyboard focus.
    var onFocus: (() -> Void)?
    private let prompt = NSTextField(labelWithString: "")
    var onRun: ((String) -> Void)?
    var onRunInTerminal: ((String) -> Void)?
    var onEscape: (() -> Void)?
    var onToggleConsole: (() -> Void)?
    /// Names (or paths) of the selected items to insert.
    var selectionProvider: ((_ fullPaths: Bool) -> [String])?
    private let preferences: Preferences
    private var historyIndex: Int?
    private var draft = ""

    init(preferences: Preferences) {
        self.preferences = preferences
        super.init(frame: .zero)
        let top = NSBox()
        top.boxType = .separator
        prompt.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        prompt.textColor = .secondaryLabelColor
        prompt.lineBreakMode = .byTruncatingHead
        prompt.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderAttributedString = NSAttributedString(
            string: "Shell command in this folder   ↩ run · ⌘↩ in Terminal · ⌥↩ insert selection · ! focuses",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.placeholderTextColor])
        field.delegate = self
        field.onFocus = { [weak self] in self?.onFocus?() }
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        let terminal = ConsoleViewController.iconButton("terminal", "Run in Terminal (⌘↩)", self, #selector(runInTerminalClicked))
        let console = ConsoleViewController.iconButton("rectangle.bottomthird.inset.filled", "Show Console (⌥⌘J)", self, #selector(consoleClicked))
        for v in [top, prompt, field, terminal, console] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            top.topAnchor.constraint(equalTo: topAnchor),
            top.leadingAnchor.constraint(equalTo: leadingAnchor),
            top.trailingAnchor.constraint(equalTo: trailingAnchor),
            prompt.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            prompt.centerYAnchor.constraint(equalTo: centerYAnchor),
            prompt.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.35),
            field.leadingAnchor.constraint(equalTo: prompt.trailingAnchor, constant: 6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.trailingAnchor.constraint(equalTo: terminal.leadingAnchor, constant: -8),
            terminal.trailingAnchor.constraint(equalTo: console.leadingAnchor, constant: -8),
            terminal.centerYAnchor.constraint(equalTo: centerYAnchor),
            console.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            console.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setDirectory(_ url: URL) {
        prompt.stringValue = Formatting.abbreviatedPath(url) + " ❯"
        prompt.toolTip = url.path
    }

    func focus() {
        isHidden = false
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
    }

    var hasFocus: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.delegate === field
    }

    // MARK: Keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            flags.contains(.command) ? submit(inTerminal: true) : submit(inTerminal: false)
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            insertSelection(fullPaths: flags.contains(.shift))
            return true
        case #selector(NSResponder.moveUp(_:)):
            stepHistory(-1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            stepHistory(1)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onEscape?()
            return true
        default:
            return false
        }
    }

    func submit(inTerminal: Bool) {
        let command = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { NSSound.beep(); return }
        var history = preferences.commandHistory
        if history.last != command { history.append(command) }
        preferences.commandHistory = history
        historyIndex = nil
        field.stringValue = ""
        if inTerminal { onRunInTerminal?(command) } else { onRun?(command) }
    }

    func insertSelection(fullPaths: Bool) {
        guard let names = selectionProvider?(fullPaths), !names.isEmpty else { NSSound.beep(); return }
        let text = names.map(UserShell.quote).joined(separator: " ")
        let editor = field.currentEditor() as? NSTextView
        let range = editor?.selectedRange() ?? NSRange(location: (field.stringValue as NSString).length, length: 0)
        let current = field.stringValue as NSString
        let before = range.location > 0 && !current.substring(to: range.location).hasSuffix(" ") ? " " : ""
        let insertion = before + text + " "
        if let editor {
            editor.insertText(insertion, replacementRange: range)
        } else {
            field.stringValue += insertion
        }
    }

    private func stepHistory(_ delta: Int) {
        let history = preferences.commandHistory
        guard !history.isEmpty else { return }
        if historyIndex == nil {
            guard delta < 0 else { return }
            draft = field.stringValue
            historyIndex = history.count
        }
        let next = historyIndex! + delta
        if next >= history.count {
            historyIndex = nil
            field.stringValue = draft
        } else {
            historyIndex = max(0, next)
            field.stringValue = history[historyIndex!]
        }
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
    }

    @objc private func runInTerminalClicked() {
        if field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            onRunInTerminal?("")
        } else {
            submit(inTerminal: true)
        }
    }

    @objc private func consoleClicked() { onToggleConsole?() }
}

/// A text field that says when it receives keyboard focus.
final class FocusReportingTextField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }
}
