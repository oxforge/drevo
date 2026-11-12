import AppKit
import FmanCore

/// Breadcrumb path: icon + name segments with chevrons. When space runs short, middle
/// segments collapse into a "…" button whose menu lists them.
@MainActor
final class PathBarView: NSView {
    var onNavigate: ((URL) -> Void)?
    private let stack = NSStackView()
    private(set) var url: URL?
    var isActive = false { didSet { refreshColors() } }
    private var units: [NSView] = []
    private var segmentButtons: [SegmentButton] = []
    private var segmentURLs: [URL] = []
    private let ellipsis = NSButton(title: "…", target: nil, action: nil)
    private var ellipsisUnit = NSStackView()
    private var lastLayoutWidth: CGFloat = -1
    private var hiddenURLs: [URL] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ellipsis.isBordered = false
        ellipsis.bezelStyle = .inline
        ellipsis.target = self
        ellipsis.action = #selector(showHidden(_:))
        ellipsis.contentTintColor = .secondaryLabelColor
        ellipsis.toolTip = "Hidden folders"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Folders from the display root down to `url`: Home-relative inside Home, else from the volume.
    static func segments(for url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var chain: [URL] = []
        var u = url.standardizedFileURL
        let homePath = home.standardizedFileURL.path
        while true {
            chain.append(u)
            if u.path == homePath || u.path == "/" { break }
            if (try? u.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true { break }
            let parent = u.deletingLastPathComponent()
            if parent.path == u.path { break }
            u = parent
        }
        return chain.reversed()
    }

    func show(_ url: URL) {
        self.url = url
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        units.removeAll()
        segmentButtons.removeAll()
        segmentURLs = Self.segments(for: url)
        for (i, seg) in segmentURLs.enumerated() {
            let button = SegmentButton(url: seg, isLast: i == segmentURLs.count - 1)
            button.target = self
            button.action = #selector(segmentClicked(_:))
            let unit = Self.unit(with: button, chevron: i > 0)
            stack.addArrangedSubview(unit)
            units.append(unit)
            segmentButtons.append(button)
            if i == 0 {
                ellipsisUnit = Self.unit(with: ellipsis, chevron: true)
                stack.addArrangedSubview(ellipsisUnit)
            }
        }
        lastLayoutWidth = -1
        refreshColors()
        needsLayout = true
    }

    /// A segment and the chevron before it, shown and hidden together.
    private static func unit(with control: NSView, chevron: Bool) -> NSStackView {
        let unit = NSStackView()
        unit.orientation = .horizontal
        unit.spacing = 2
        if chevron {
            let c = NSImageView(image: NSImage(systemSymbolName: "chevron.compact.right", accessibilityDescription: nil)!)
            c.symbolConfiguration = .init(pointSize: 11, weight: .regular)
            c.contentTintColor = .tertiaryLabelColor
            unit.addArrangedSubview(c)
        }
        unit.addArrangedSubview(control)
        return unit
    }

    override func layout() {
        super.layout()
        guard bounds.width != lastLayoutWidth, !units.isEmpty else { return }
        lastLayoutWidth = bounds.width
        fitSegments()
    }

    /// Shows as many segments as fit: always the last, then the first, then from the end back.
    private func fitSegments() {
        units.forEach { $0.isHidden = false }
        ellipsisUnit.isHidden = true
        let widths = units.map { $0.fittingSize.width + stack.spacing }
        let available = bounds.width
        guard widths.reduce(0, +) > available else { hiddenURLs = []; return }
        let ellipsisWidth = ellipsisUnit.fittingSize.width + stack.spacing
        var visible = Set([units.count - 1])
        var used = widths[units.count - 1] + ellipsisWidth
        if units.count > 1, used + widths[0] <= available {
            visible.insert(0)
            used += widths[0]
        }
        var i = units.count - 2
        while i > 0, used + widths[i] <= available {
            visible.insert(i)
            used += widths[i]
            i -= 1
        }
        for (idx, unit) in units.enumerated() { unit.isHidden = !visible.contains(idx) }
        hiddenURLs = segmentURLs.indices.filter { !visible.contains($0) }.map { segmentURLs[$0] }
        ellipsisUnit.isHidden = hiddenURLs.isEmpty
        // The first segment sits before the ellipsis; if it's hidden too, the ellipsis leads.
        if let firstChevron = (ellipsisUnit.arrangedSubviews.first as? NSImageView) {
            firstChevron.isHidden = !visible.contains(0)
        }
    }

    private func refreshColors() {
        for b in segmentButtons {
            b.contentTintColor = b.isLast ? (isActive ? .labelColor : .secondaryLabelColor) : .secondaryLabelColor
            b.font = .systemFont(ofSize: 12, weight: b.isLast && isActive ? .semibold : .regular)
        }
    }

    @objc private func segmentClicked(_ sender: SegmentButton) {
        onNavigate?(sender.url)
    }

    @objc private func showHidden(_ sender: NSButton) {
        let menu = NSMenu()
        for url in hiddenURLs {
            let item = menu.addItem(withTitle: Formatting.displayName(url), action: #selector(hiddenChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            let icon = FileIcons.shared.icon(for: url).copy() as! NSImage
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func hiddenChosen(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { onNavigate?(url) }
    }

    final class SegmentButton: NSButton {
        let url: URL
        let isLast: Bool

        init(url: URL, isLast: Bool) {
            self.url = url
            self.isLast = isLast
            super.init(frame: .zero)
            isBordered = false
            bezelStyle = .inline
            title = Formatting.displayName(url)
            let icon = FileIcons.shared.icon(for: url).copy() as! NSImage
            icon.size = NSSize(width: 14, height: 14)
            image = icon
            imagePosition = .imageLeading
            imageHugsTitle = true
            (cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
            setContentCompressionResistancePriority(isLast ? .defaultHigh : .defaultLow, for: .horizontal)
            toolTip = url.path
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }
    }
}

/// Header above a pane: path bar, optional filter field, and the active-pane accent line.
@MainActor
final class PaneHeaderView: NSView {
    let pathBar = PathBarView()
    let badge = NSTextField(labelWithString: "")
    private let accentLine = NSView()
    private let separator = NSBox()
    var onClick: (() -> Void)?

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
        for v in [pathBar, badge, accessoryStack, accentLine, separator] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            pathBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            pathBar.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathBar.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8),
            pathBar.trailingAnchor.constraint(lessThanOrEqualTo: accessoryStack.leadingAnchor, constant: -8),
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
        super.mouseDown(with: event)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            accentLine.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        }
    }
}

/// Footer below a pane: counts and free space.
@MainActor
final class StatusBarView: NSView {
    let left = NSTextField(labelWithString: "")
    let right = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let top = NSBox()
        top.boxType = .separator
        for l in [left, right] {
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.lineBreakMode = .byTruncatingTail
        }
        right.alignment = .right
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [top, left, right] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            top.topAnchor.constraint(equalTo: topAnchor),
            top.leadingAnchor.constraint(equalTo: leadingAnchor),
            top.trailingAnchor.constraint(equalTo: trailingAnchor),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(items: [FileItem], selected: [FileItem], directory: URL) {
        var text = Formatting.itemCount(items.count)
        if !selected.isEmpty {
            let bytes = selected.compactMap(\.size).reduce(0, +)
            text += " · \(selected.count) selected"
            if bytes > 0 { text += ", \(Formatting.size(bytes))" }
        }
        left.stringValue = text
        if let free = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            right.stringValue = "\(Formatting.size(free)) available"
        } else {
            right.stringValue = ""
        }
    }
}
