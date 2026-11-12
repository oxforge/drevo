import AppKit
import DrevoCore
import QuickLookThumbnailing

/// The last column in Columns view: a file's preview, or a summary when several items are
/// selected (count, total size, kinds).
@MainActor
final class FilePreviewView: NSView {
    let items: [FileItem]
    private let imageView = NSImageView()
    /// Total size; "Calculating…" while selected folders are measured.
    let sizeLabel = NSTextField(labelWithString: "")
    let titleLabel = NSTextField(wrappingLabelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")

    /// How long a summary must stay up before its folders are walked: extending a selection
    /// with ⇧↓ replaces the preview on every key press.
    static let measureDelay: TimeInterval = 0.15
    /// Measures one folder off the main thread; asked to stop through its second argument.
    /// Tests replace it.
    var measureFolder: @Sendable (URL, () -> Bool) -> Int64 = { CopyEngine.measure($0, isCancelled: $1).bytes }
    /// Stops the folder walk that is waiting to start or running; nil when there is none.
    private(set) var measurement: CancellationToken?
    /// False while "Calculating…" still has to be replaced by the measured total.
    private var totalIsKnown = true
    private var wasInWindow = false

    init(items: [FileItem], relativeDates: Bool) {
        precondition(!items.isEmpty)
        self.items = items
        super.init(frame: .zero)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 3
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        sizeLabel.font = .systemFont(ofSize: 11)
        sizeLabel.setContentCompressionResistancePriority(.init(250), for: .horizontal)

        let grid: NSGridView
        if items.count == 1 {
            let item = items[0]
            imageView.image = FileIcons.shared.icon(for: item.url)
            titleLabel.stringValue = item.name
            subtitleLabel.stringValue = [item.kind, item.size.map { Formatting.size($0) }].compactMap { $0 }.joined(separator: " — ")
            grid = NSGridView(views: [
                [Self.key("Created"), Self.value(Formatting.date(item.created, relative: relativeDates))],
                [Self.key("Modified"), Self.value(Formatting.date(item.modified, relative: relativeDates))],
            ])
        } else {
            imageView.image = Self.stackedIcons(items)
            titleLabel.stringValue = "\(items.count) items"
            subtitleLabel.stringValue = Self.breakdown(items)
            grid = NSGridView(views: [
                [Self.key("Size"), sizeLabel],
                [Self.key("Kinds"), Self.value(Self.kinds(items))],
                [Self.key("Last modified"), Self.value(Formatting.date(items.compactMap(\.modified).max(), relative: relativeDates))],
            ])
            showTotalSize()
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 4
        grid.columnSpacing = 8

        let stack = NSStackView(views: [imageView, titleLabel, subtitleLabel, grid])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(16, after: imageView)
        stack.setCustomSpacing(16, after: subtitleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            imageView.widthAnchor.constraint(equalToConstant: 128),
            imageView.heightAnchor.constraint(equalToConstant: 128),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            grid.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
        if items.count == 1 { loadThumbnail(items[0]) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Summary

    /// "3 files, 1 folder".
    static func breakdown(_ items: [FileItem]) -> String {
        let folders = items.filter(\.isContainer).count
        let files = items.count - folders
        var parts: [String] = []
        if files > 0 { parts.append(files == 1 ? "1 file" : "\(files) files") }
        if folders > 0 { parts.append(folders == 1 ? "1 folder" : "\(folders) folders") }
        return parts.joined(separator: ", ")
    }

    /// Distinct kinds, most common first: "Zip archive, JPEG image +2 more".
    static func kinds(_ items: [FileItem]) -> String {
        var counts: [String: Int] = [:]
        for item in items { counts[item.kind, default: 0] += 1 }
        let ordered = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        let shown = ordered.prefix(2).joined(separator: ", ")
        return ordered.count > 2 ? "\(shown) +\(ordered.count - 2) more" : shown
    }

    // MARK: Total size

    /// File sizes add up at once; folders are measured in the background while the preview
    /// is in a view (`startMeasuring`).
    private func showTotalSize() {
        if items.contains(where: \.isDirectory) {
            totalIsKnown = false
            sizeLabel.stringValue = "Calculating…"
        } else {
            sizeLabel.stringValue = Formatting.size(items.compactMap(\.size).reduce(0, +))
        }
    }

    /// Walks the selected folders once the preview has been in a view for `measureDelay`.
    private func startMeasuring() {
        guard superview != nil, !totalIsKnown, measurement == nil else { return }
        let token = CancellationToken()
        measurement = token
        let fileBytes = items.compactMap(\.size).reduce(0, +)
        let folders = items.filter(\.isDirectory).map(\.url)
        let measure = measureFolder
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.measureDelay) { [weak self] in
            var total = fileBytes
            for folder in folders where !token.isCancelled {
                total += measure(folder) { token.isCancelled }
            }
            guard !token.isCancelled else { return }
            onMainRunLoop {
                // Not the current walk any more if the preview was removed in the meantime.
                guard let self, self.measurement === token else { return }
                self.measurement = nil
                self.totalIsKnown = true
                self.sizeLabel.stringValue = Formatting.size(total)
            }
        }
    }

    private func stopMeasuring() {
        measurement?.cancel()
        measurement = nil
    }

    // A preview that is replaced, or whose pane goes away, must not keep walking folders.
    // It stops itself here, because whoever removes it doesn't know about the walk.

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil { stopMeasuring() } else { startMeasuring() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            wasInWindow = true
            startMeasuring() // again, if it left a window earlier and has come back
        } else if wasInWindow {
            wasInWindow = false
            stopMeasuring()
        }
    }

    deinit { measurement?.cancel() }

    /// Up to three icons fanned out, front item first.
    static func stackedIcons(_ items: [FileItem]) -> NSImage {
        let icons = items.prefix(3).map { FileIcons.shared.icon(for: $0.url) }
        let side: CGFloat = 104
        let step: CGFloat = 12
        return NSImage(size: NSSize(width: 128, height: 128), flipped: false) { _ in
            for (i, icon) in icons.enumerated().reversed() {
                let offset = CGFloat(i) * step
                icon.draw(in: NSRect(x: offset, y: CGFloat(icons.count - 1 - i) * step, width: side, height: side),
                          from: .zero, operation: .sourceOver, fraction: i == 0 ? 1 : 0.85)
            }
            return true
        }
    }

    // MARK: Helpers

    /// Labels keep their full width; a long value truncates instead.
    private static func key(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.setContentCompressionResistancePriority(.init(800), for: .horizontal)
        return l
    }

    private static func value(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.lineBreakMode = .byTruncatingTail
        l.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        l.toolTip = s
        return l
    }

    private func loadThumbnail(_ item: FileItem) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 128, height: 128), scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let rep else { return }
            let image = rep.nsImage
            DispatchQueue.main.async { self?.imageView.image = image }
        }
    }
}
