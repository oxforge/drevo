import AppKit
import DrevoCore

/// Help ▸ Keyboard Shortcuts: every command and its keys, grouped.
@MainActor
enum ShortcutsWindow {
    private static var window: NSWindow?

    static func text(keyMap: KeyMap) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: 260)]
        para.paragraphSpacing = 2
        for category in CommandCategory.allCases {
            let specs = CommandRegistry.all.filter { $0.category == category }
            guard !specs.isEmpty else { continue }
            out.append(NSAttributedString(string: (out.length == 0 ? "" : "\n") + category.rawValue + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor,
            ]))
            for spec in specs {
                let keys = keyMap.keys(for: spec.id).map(\.description).joined(separator: "   ")
                out.append(NSAttributedString(string: "\(spec.title)\t\(keys.isEmpty ? "—" : keys)\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: para,
                ]))
            }
        }
        out.append(NSAttributedString(string: "\nAlso: type to filter (* and ? are wildcards; ⌫ deletes, Esc clears) · / or ~ edits the path · fn↓/fn↑ page, fn←/fn→ first/last (⇧ extends)\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return out
    }

    static func show(keyMap: KeyMap) {
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Keyboard Shortcuts"
            w.isReleasedWhenClosed = false
            let scroll = NSTextView.scrollableTextView()
            (scroll.documentView as? NSTextView)?.isEditable = false
            (scroll.documentView as? NSTextView)?.textContainerInset = NSSize(width: 16, height: 16)
            w.contentView = scroll
            w.center()
            window = w
            return w
        }()
        textView?.textStorage?.setAttributedString(text(keyMap: keyMap))
        w.makeKeyAndOrderFront(nil)
    }

    /// Keeps an open window in step when keys change (Settings ▸ Keys, keybindings.json).
    static func refresh(keyMap: KeyMap) {
        guard window?.isVisible == true else { return }
        textView?.textStorage?.setAttributedString(text(keyMap: keyMap))
    }

    static func close() { window?.close() }

    /// What the window shows, if it's open.
    static var shownText: String? { window?.isVisible == true ? textView?.string : nil }

    private static var textView: NSTextView? {
        (window?.contentView as? NSScrollView)?.documentView as? NSTextView
    }
}
