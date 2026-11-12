import AppKit
import FmanCore

/// Output of commands run from the command line: a transcript with a status header.
@MainActor
final class ConsoleViewController: NSViewController {
    private let textView = NSTextView()
    private let status = NSTextField(labelWithString: "Console")
    private let spinner = NSProgressIndicator()
    private let stopButton = NSButton()
    var onStop: (() -> Void)?
    var onHide: (() -> Void)?
    private let maxCharacters = 400_000

    override func loadView() {
        let header = NSView()
        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        stopButton.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: "Stop")
        stopButton.isBordered = false
        stopButton.toolTip = "Stop (⌘.)"
        stopButton.target = self
        stopButton.action = #selector(stop)
        stopButton.isEnabled = false
        let clear = Self.iconButton("trash", "Clear", self, #selector(clear(_:)))
        let hide = Self.iconButton("chevron.down", "Hide Console (⌥⌘J)", self, #selector(hide))
        let buttons = NSStackView(views: [stopButton, clear, hide])
        buttons.spacing = 8
        for v in [spinner, status, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(v)
        }
        let sep = NSBox()
        sep.boxType = .separator

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let root = NSView()
        for v in [sep, header, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            sep.topAnchor.constraint(equalTo: root.topAnchor),
            sep.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: sep.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 24),
            spinner.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            spinner.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 6),
            status.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -10),
            buttons.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            buttons.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
        view = root
    }

    static func iconButton(_ symbol: String, _ tip: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: target, action: action)
        b.isBordered = false
        b.toolTip = tip
        b.contentTintColor = .secondaryLabelColor
        return b
    }

    var transcript: String { textView.string }

    func begin(command: String, directory: URL) {
        _ = view
        let header = NSAttributedString(string: (textView.string.isEmpty ? "" : "\n") + "❯ \(command)\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.labelColor,
        ])
        appendAttributed(header)
        status.stringValue = "Running “\(command)” in \(Formatting.abbreviatedPath(directory))"
        spinner.startAnimation(nil)
        stopButton.isEnabled = true
    }

    func append(_ text: String, isError: Bool) {
        appendAttributed(NSAttributedString(string: ANSI.strip(text), attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: isError ? NSColor.systemRed : NSColor.labelColor,
        ]))
    }

    func finish(status code: Int32?, signal: Int32?, duration: TimeInterval) {
        let ok = code == 0
        let what = code.map { "exit \($0)" } ?? "stopped (signal \(signal ?? 0))"
        let line = String(format: "%@%@ · %.2f s\n", textView.string.hasSuffix("\n") || textView.string.isEmpty ? "" : "\n", what, duration)
        appendAttributed(NSAttributedString(string: line, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: ok ? NSColor.secondaryLabelColor : NSColor.systemOrange,
        ]))
        status.stringValue = "Last command: \(what)"
        spinner.stopAnimation(nil)
        stopButton.isEnabled = false
    }

    private func appendAttributed(_ s: NSAttributedString) {
        guard let storage = textView.textStorage else { return }
        let atBottom = (textView.enclosingScrollView?.verticalScroller?.floatValue ?? 1) > 0.98 || storage.length == 0
        storage.append(s)
        if storage.length > maxCharacters {
            storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - maxCharacters))
        }
        if atBottom {
            if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
            textView.scrollToEndOfDocument(nil)
        }
    }

    @objc func clear(_ sender: Any?) {
        textView.string = ""
    }

    @objc private func stop() { onStop?() }
    @objc private func hide() { onHide?() }
}

/// The mc-style command line under the panes: runs in the active pane's folder.
/// Return runs here, ⌘Return in the terminal app, ⌥Return inserts selected names,
/// ↑/↓ walk history, Esc goes back to the pane.
@MainActor
final class CommandBar: NSView, NSTextFieldDelegate {
    let field = NSTextField()
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

/// Runs command-line commands for one window and feeds the console.
@MainActor
final class ShellSession {
    private(set) var running: ShellCommand?
    private let console: ConsoleViewController
    private let preferences: Preferences
    var onFinish: (() -> Void)?
    /// Tests use a shell without the user's rc files.
    var shellOverride: (shell: String, flags: [String])?

    init(console: ConsoleViewController, preferences: Preferences) {
        self.console = console
        self.preferences = preferences
    }

    var isRunning: Bool { running?.isRunning ?? false }

    @discardableResult
    func run(_ command: String, in directory: URL) -> Bool {
        guard !isRunning else { return false }
        let shell = shellOverride?.shell ?? UserShell.loginShell()
        let flags = shellOverride?.flags ?? UserShell.flags(interactive: preferences.interactiveShell)
        let cmd = ShellCommand(command: command, directory: directory, shell: shell, flags: flags)
        let started = Date()
        cmd.onOutput = { [weak self] text, isError in
            onMainRunLoop { self?.console.append(text, isError: isError) }
        }
        cmd.onExit = { [weak self] status, signal in
            onMainRunLoop {
                guard let self else { return }
                self.console.finish(status: status, signal: signal, duration: Date().timeIntervalSince(started))
                self.running = nil
                self.onFinish?()
            }
        }
        console.begin(command: command, directory: directory)
        do {
            try cmd.start()
            running = cmd
            return true
        } catch {
            console.append("\(error.localizedDescription)\n", isError: true)
            console.finish(status: 127, signal: nil, duration: 0)
            return false
        }
    }

    func stop() {
        running?.interrupt()
    }
}

/// Runs `block` on the main thread through the main run loop (in order), so it also runs
/// while something spins a nested run loop (modal sessions, tests).
nonisolated func onMainRunLoop(_ block: @escaping @MainActor () -> Void) {
    let main = CFRunLoopGetMain()
    CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
        MainActor.assumeIsolated { block() }
    }
    CFRunLoopWakeUp(main)
}
