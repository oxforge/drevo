import AppKit
import DrevoCore

/// One tab of a pane: where it is, how it shows it and where it has been. The pane works
/// on the active tab's state directly; the others wait here until they are switched to.
struct PaneTab: Equatable {
    var history: NavigationHistory
    var viewMode: ViewMode
    var sort: FileSort
    /// The item the cursor was on when the tab was left.
    var selection: URL?

    var directory: URL { history.current }
}

/// The strip of tabs under a pane's header. The pane hides it while there is one tab.
@MainActor
final class PaneTabBar: NSView {
    static let height: CGFloat = 26
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    private(set) var titles: [String] = []
    private(set) var activeIndex = 0
    private let stack = NSStackView()
    private let separator = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 2
        separator.boxType = .separator
        for v in [stack, separator] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var items: [PaneTabItemView] { stack.arrangedSubviews.compactMap { $0 as? PaneTabItemView } }

    func show(titles: [String], tooltips: [String], active: Int) {
        guard titles != self.titles || active != activeIndex || items.count != titles.count else { return }
        self.titles = titles
        activeIndex = active
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, title) in titles.enumerated() {
            let item = PaneTabItemView(title: title, isActive: i == active)
            item.toolTip = tooltips[i]
            item.onSelect = { [weak self] in self?.onSelect?(i) }
            item.onClose = { [weak self] in self?.onClose?(i) }
            stack.addArrangedSubview(item)
        }
    }
}

/// A tab: its folder's name and a close button. A click selects it, a middle click closes it.
@MainActor
final class PaneTabItemView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    let isActive: Bool
    private let label: NSTextField
    private let close = NSButton()

    init(title: String, isActive: Bool) {
        self.isActive = isActive
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11, weight: isActive ? .semibold : .regular)
        label.textColor = isActive ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = .center
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        close.symbolConfiguration = .init(pointSize: 8, weight: .bold)
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.target = self
        close.action = #selector(closeClicked(_:))
        close.toolTip = "Close tab"
        for v in [close, label] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            close.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: close.trailingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var title: String { label.stringValue }

    override func draw(_ dirtyRect: NSRect) {
        guard isActive else { return }
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }

    override func mouseDown(with event: NSEvent) { onSelect?() }
    override func otherMouseDown(with event: NSEvent) { onClose?() }
    @objc private func closeClicked(_ sender: Any?) { onClose?() }
}
