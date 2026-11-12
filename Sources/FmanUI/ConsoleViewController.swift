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
    /// The transcript keeps this much (UTF-16 units); older text goes first.
    static let maxCharacters = 400_000
    static let skippedNote = "… output skipped …\n"
    /// The most output worth holding back between two updates: with the note it fills
    /// the transcript exactly.
    static var backlogLimit: Int { maxCharacters - (skippedNote as NSString).length }
    /// New output scrolls into view. Off while the user has scrolled up to read.
    private var followsOutput = true

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
        // Lay out what is looked at, not the whole transcript after every update: a full
        // one takes ~0.3 s to lay out, and fast output replaces it many times a second.
        textView.layoutManager?.allowsNonContiguousLayout = true
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        NotificationCenter.default.addObserver(self, selector: #selector(userScrolled(_:)),
                                               name: NSScrollView.didLiveScrollNotification, object: scroll)

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
    /// The transcript with its colours (tests).
    var attributedTranscript: NSAttributedString { textView.attributedString() }

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

    /// A dim status line (not command output).
    func note(_ text: String) {
        _ = view
        appendAttributed(NSAttributedString(string: text + "\n", attributes: Self.noteAttributes))
    }

    private static let noteAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]

    private static func outputAttributes(isError: Bool) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: isError ? NSColor.systemRed : NSColor.labelColor,
        ]
    }

    /// One message (a command's output arrives in batches instead).
    func append(_ text: String, isError: Bool) {
        appendAttributed(NSAttributedString(string: ANSI.strip(text), attributes: Self.outputAttributes(isError: isError)))
    }

    /// Everything a command printed since the last update, as one edit of the transcript.
    func append(_ batch: OutputBacklog.Batch) {
        guard !batch.isEmpty else { return }
        let text = NSMutableAttributedString()
        if batch.skipped {
            let lineBreak = endsWithLineBreak ? "" : "\n"
            text.append(NSAttributedString(string: lineBreak + Self.skippedNote, attributes: Self.noteAttributes))
        }
        for run in batch.runs {
            text.append(NSAttributedString(string: run.text, attributes: Self.outputAttributes(isError: run.isError)))
        }
        appendAttributed(text)
    }

    private var endsWithLineBreak: Bool {
        guard let text = textView.textStorage?.mutableString, text.length > 0 else { return true }
        return text.hasSuffix("\n")
    }

    func finish(status code: Int32?, signal: Int32?, duration: TimeInterval) {
        let ok = code == 0
        let what = code.map { "exit \($0)" } ?? "stopped (signal \(signal ?? 0))"
        let line = String(format: "%@%@ · %.2f s\n", endsWithLineBreak ? "" : "\n", what, duration)
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
        storage.beginEditing()
        storage.append(s)
        if storage.length > Self.maxCharacters {
            storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - Self.maxCharacters))
        }
        storage.endEditing()
        if followsOutput {
            textView.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
        }
    }

    /// The user scrolled: follow new output only while the end of the transcript is in view.
    @objc private func userScrolled(_ note: Notification) {
        followsOutput = textView.visibleRect.maxY >= textView.bounds.maxY - 2
    }

    @objc func clear(_ sender: Any?) {
        textView.string = ""
        followsOutput = true
    }

    @objc private func stop() { onStop?() }
    @objc private func hide() { onHide?() }
}
