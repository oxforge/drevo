import AppKit
import FmanCore

/// Get Info (⌘I): a small panel with an item's facts; folder size is computed in the background.
@MainActor
final class InfoPanel: NSWindowController, NSWindowDelegate {
    private static var open: [InfoPanel] = []
    let url: URL
    private let sizeLabel = NSTextField(labelWithString: "Calculating…")
    /// Stops the folder walk when the panel closes.
    let measurement = CancellationToken()

    static func show(for url: URL, relativeDates: Bool) {
        if let existing = open.first(where: { $0.url == url }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let panel = InfoPanel(url: url, relativeDates: relativeDates)
        open.append(panel)
        panel.window?.center()
        if let key = NSApp.keyWindow {
            panel.window?.setFrameTopLeftPoint(NSPoint(x: key.frame.midX - 160 + CGFloat(open.count * 20), y: key.frame.maxY - 80 - CGFloat(open.count * 20)))
        }
        panel.showWindow(nil)
    }

    /// `show(for:relativeDates:)` is the way in; tests build a panel without showing it.
    init(url: URL, relativeDates: Bool) {
        self.url = url
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 380),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "\(url.lastPathComponent) Info"
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.delegate = self
        build(relativeDates: relativeDates)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build(relativeDates: Bool) {
        let item = try? FileItem(url: url)
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let icon = NSImageView(image: FileIcons.shared.icon(for: url))
        icon.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(wrappingLabelWithString: url.lastPathComponent)
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.isSelectable = true

        func row(_ key: String, _ value: NSView) -> [NSView] {
            let k = NSTextField(labelWithString: key)
            k.font = .systemFont(ofSize: 11)
            k.textColor = .secondaryLabelColor
            return [k, value]
        }
        func text(_ s: String) -> NSTextField {
            let t = NSTextField(wrappingLabelWithString: s)
            t.font = .systemFont(ofSize: 11)
            t.isSelectable = true
            return t
        }
        sizeLabel.font = .systemFont(ofSize: 11)
        let perms = (attrs[.posixPermissions] as? NSNumber).map { Self.permissionString($0.intValue) } ?? "—"
        let owner = [attrs[.ownerAccountName] as? String, attrs[.groupOwnerAccountName] as? String].compactMap { $0 }.joined(separator: ":")
        let grid = NSGridView(views: [
            row("Kind", text(item?.kind ?? "—")),
            row("Size", sizeLabel),
            row("Where", text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)),
            row("Created", text(Formatting.date(item?.created, relative: relativeDates))),
            row("Modified", text(Formatting.date(item?.modified, relative: relativeDates))),
            row("Permissions", text("\(perms)  \(owner)")),
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        grid.column(at: 1).width = 200

        let stack = NSStackView(views: [icon, name, grid])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 16, bottom: 20, right: 16)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
        ])
        window?.contentView = stack

        if item?.isDirectory == true {
            let url = self.url
            let token = measurement
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let (bytes, items) = CopyEngine.measure(url) { token.isCancelled }
                guard !token.isCancelled else { return }
                onMainRunLoop {
                    self?.sizeLabel.stringValue = "\(Formatting.size(bytes)) for \(Formatting.itemCount(max(0, items - 1)))"
                }
            }
        } else {
            sizeLabel.stringValue = item?.size.map { "\(Formatting.size($0)) (\($0.formatted()) bytes)" } ?? "—"
        }
    }

    static func permissionString(_ mode: Int) -> String {
        let chars = Array("rwxrwxrwx")
        return String((0..<9).map { mode & (1 << (8 - $0)) != 0 ? chars[$0] : "-" })
    }

    func windowWillClose(_ notification: Notification) {
        measurement.cancel()
        Self.open.removeAll { $0 === self }
    }
}
