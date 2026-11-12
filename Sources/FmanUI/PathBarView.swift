import AppKit
import FmanCore

/// Breadcrumb path: icon + name segments with chevrons. When space runs short, middle
/// segments collapse into a "…" button whose menu lists them.
@MainActor
final class PathBarView: NSView {
    var onNavigate: ((URL) -> Void)?
    /// Clicking the current folder's segment edits the path (Windows Explorer style).
    var onEditRequest: (() -> Void)?
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
        if sender.isLast {
            onEditRequest?()
        } else {
            onNavigate?(sender.url)
        }
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
