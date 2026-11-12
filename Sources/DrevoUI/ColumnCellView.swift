import AppKit
import DrevoCore

/// Name cell with a chevron for folders.
final class ColumnCellView: NSTableCellView, NameEditingCell {
    private let name = NameCellView(frame: .zero)
    var nameLabel: NSTextField { name.label }
    private let chevron = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        chevron.contentTintColor = .tertiaryLabelColor
        for v in [name, chevron] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        textField = name.label
        imageView = name.icon
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.topAnchor.constraint(equalTo: topAnchor),
            name.bottomAnchor.constraint(equalTo: bottomAnchor),
            name.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -2),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: FileItem, size: RowSize, showExtension: Bool) {
        name.configure(item, size: size, showExtension: showExtension)
        chevron.isHidden = !item.isContainer
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { chevron.contentTintColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .tertiaryLabelColor }
    }
}
