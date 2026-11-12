import AppKit
import DrevoCore

/// The bottom row of key hints (mc's function-key bar): each hint is a button too.
@MainActor
final class KeyHintBar: NSView {
    /// Hints in order of importance; later ones drop out first when the window is narrow.
    static let hints: [(CommandID, String)] = [
        (.nextPane, "Switch"), (.copyToOtherPane, "Copy →"), (.moveToOtherPane, "Move →"), (.rename, "Rename"),
        (.newFolder, "Folder"), (.moveToTrash, "Trash"), (.quickLook, "Preview"), (.edit, "Edit"),
        (.runCommand, "Shell"), (.goToPath, "Go to"), (.toggleHidden, "Hidden"), (.commandPalette, "Commands"),
    ]

    private let stack = NSStackView()
    var onCommand: ((CommandID) -> Void)?
    private(set) var shownCommands: [CommandID] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let top = NSBox()
        top.boxType = .separator
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.detachesHiddenViews = true
        for v in [top, stack] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            top.topAnchor.constraint(equalTo: topAnchor),
            top.leadingAnchor.constraint(equalTo: leadingAnchor),
            top.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The key shown for a command: F-keys first (the mc habit), else the first binding.
    static func displayKey(_ id: CommandID, keyMap: KeyMap) -> String? {
        let keys = keyMap.keys(for: id)
        let f = keys.first { if case .named(let k) = $0.key { return k.functionNumber != nil && $0.modifiers.isEmpty } else { return false } }
        return (f ?? keys.first)?.description
    }

    func reload(keyMap: KeyMap) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        shownCommands = []
        for (i, (id, title)) in Self.hints.enumerated() {
            guard let key = Self.displayKey(id, keyMap: keyMap) else { continue }
            let chip = HintChip(key: key, title: title, command: id) { [weak self] in self?.onCommand?(id) }
            stack.addArrangedSubview(chip)
            stack.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: Float(1000 - i * 10)), for: chip)
            shownCommands.append(id)
        }
    }

    final class HintChip: NSView {
        let command: CommandID
        private let action: () -> Void

        init(key: String, title: String, command: CommandID, action: @escaping () -> Void) {
            self.command = command
            self.action = action
            super.init(frame: .zero)
            let cap = KeycapView(key, small: true)
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            let s = NSStackView(views: [cap, label])
            s.spacing = 4
            s.translatesAutoresizingMaskIntoConstraints = false
            addSubview(s)
            NSLayoutConstraint.activate([
                s.leadingAnchor.constraint(equalTo: leadingAnchor),
                s.trailingAnchor.constraint(equalTo: trailingAnchor),
                s.topAnchor.constraint(equalTo: topAnchor),
                s.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            toolTip = CommandRegistry.spec(command)?.title
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) { action() }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    }
}
