import AppKit
import DrevoCore

/// Header above a pane: path bar (or the path editor), optional filter field, and the
/// active-pane accent line.
@MainActor
final class PaneHeaderView: NSView, NSTextFieldDelegate, NSSearchFieldDelegate {
    let pathBar = PathBarView()
    let pathField = NSTextField()
    let filterField = NSSearchField()
    var onPathCommit: ((String) -> Void)?
    var onPathComplete: ((String) -> [String])?
    var onFilterChange: ((String) -> Void)?
    var onFilterDone: ((_ clear: Bool) -> Void)?
    var onEditingEnded: (() -> Void)?
    let badge = NSTextField(labelWithString: "")
    private let accentLine = NSView()
    private let separator = NSBox()
    var onClick: (() -> Void)?
    /// A click on the path area that isn't a folder segment: start editing the path.
    var onPathAreaClick: (() -> Void)?

    var isActive = false {
        didSet {
            pathBar.isActive = isActive
            accentLine.isHidden = !isActive
        }
    }

    /// Shows "TARGET" when this pane receives copies with 3+ panes.
    var badgeText: String? {
        didSet {
            badge.stringValue = badgeText ?? ""
            badge.isHidden = badgeText == nil
        }
    }

    let accessoryStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        accentLine.wantsLayer = true
        accentLine.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        separator.boxType = .separator
        badge.font = .systemFont(ofSize: 9, weight: .bold)
        badge.textColor = .secondaryLabelColor
        badge.isHidden = true
        accessoryStack.orientation = .horizontal
        accessoryStack.spacing = 6
        pathField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        pathField.isHidden = true
        pathField.delegate = self
        pathField.placeholderString = "Go to folder — Tab completes, Esc cancels"
        pathField.cell?.isScrollable = true
        pathField.cell?.wraps = false
        pathField.bezelStyle = .roundedBezel
        pathField.controlSize = .small
        filterField.controlSize = .small
        filterField.placeholderString = "Filter"
        filterField.isHidden = true
        filterField.delegate = self
        filterField.sendsSearchStringImmediately = true
        filterField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        accessoryStack.addArrangedSubview(filterField)
        for v in [pathBar, pathField, badge, accessoryStack, accentLine, separator] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            pathBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            pathBar.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathBar.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8),
            pathBar.trailingAnchor.constraint(lessThanOrEqualTo: accessoryStack.leadingAnchor, constant: -8),
            pathField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pathField.trailingAnchor.constraint(equalTo: accessoryStack.leadingAnchor, constant: -8),
            pathField.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: accessoryStack.leadingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            accessoryStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            accessoryStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            accentLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            accentLine.bottomAnchor.constraint(equalTo: bottomAnchor),
            accentLine.heightAnchor.constraint(equalToConstant: 2),
        ])
        isActive = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        onClick?()
        // Segment buttons take their own clicks; anything else left of the sort/filter
        // controls (blank space, chevrons) turns the path into an editable field.
        let point = convert(event.locationInWindow, from: nil)
        let controlsStart = accessoryStack.isHidden || accessoryStack.arrangedSubviews.allSatisfy(\.isHidden)
            ? bounds.maxX : accessoryStack.frame.minX
        if !isEditingPath, point.x < controlsStart - 4 {
            onPathAreaClick?()
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: Path editing

    var isEditingPath: Bool { !pathField.isHidden }

    func beginPathEditing(_ text: String, selectAll: Bool) {
        pathField.stringValue = text
        pathField.isHidden = false
        pathBar.isHidden = true
        window?.makeFirstResponder(pathField)
        let length = (text as NSString).length
        pathField.currentEditor()?.selectedRange = selectAll ? NSRange(location: 0, length: length) : NSRange(location: length, length: 0)
        // Long paths: keep the current folder (the end) in view.
        (pathField.currentEditor() as? NSTextView)?.scrollRangeToVisible(NSRange(location: length, length: 0))
    }

    func endPathEditing() {
        guard isEditingPath else { return }
        pathField.isHidden = true
        pathBar.isHidden = false
        onEditingEnded?()
    }

    // MARK: Filter

    var isFiltering: Bool { !filterField.isHidden }

    func beginFilter() {
        filterField.isHidden = false
        window?.makeFirstResponder(filterField)
    }

    /// Shows a filter typed in the file list, leaving the keyboard where it is.
    func showFilter(_ text: String) {
        filterField.isHidden = false
        filterField.stringValue = text
    }

    func clearFilter() {
        filterField.stringValue = ""
        filterField.isHidden = true
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSSearchField) === filterField { onFilterChange?(filterField.stringValue) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === pathField {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                onPathCommit?(pathField.stringValue)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                endPathEditing()
                return true
            case #selector(NSResponder.insertTab(_:)):
                complete(textView)
                return true
            default:
                return false
            }
        }
        if control === filterField {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                onFilterDone?(true)
                return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)):
                onFilterDone?(false)
                return true
            default:
                return false
            }
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Clicking elsewhere ends path editing without navigating.
        if (obj.object as? NSTextField) === pathField, isEditingPath {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.firstResponder !== self.pathField.currentEditor() else { return }
                self.endPathEditing()
            }
        }
    }

    /// Tab: extend to the common prefix; if nothing to extend, offer the choices in a menu.
    private func complete(_ editor: NSTextView) {
        let text = pathField.stringValue
        let candidates = onPathComplete?(text) ?? []
        if let completed = PathCompletion.complete(text, candidates: candidates) {
            setPath(completed)
        } else if candidates.count > 1 {
            let menu = NSMenu()
            for c in candidates.prefix(40) {
                let item = menu.addItem(withTitle: (c as NSString).lastPathComponent, action: #selector(candidateChosen(_:)), keyEquivalent: "")
                item.representedObject = c
                item.target = self
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 8, y: pathField.frame.minY - 2), in: self)
        } else {
            NSSound.beep()
        }
    }

    @objc private func candidateChosen(_ sender: NSMenuItem) {
        if let c = sender.representedObject as? String { setPath(c) }
        window?.makeFirstResponder(pathField)
    }

    private func setPath(_ s: String) {
        pathField.stringValue = s
        pathField.currentEditor()?.selectedRange = NSRange(location: (s as NSString).length, length: 0)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            accentLine.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        }
    }
}
