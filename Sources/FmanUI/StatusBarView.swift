import AppKit
import FmanCore

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
