import AppKit
import DrevoCore
import Quartz

/// Space / F3 / ⌘Y: the system Quick Look panel for the active pane's selection.
/// Arrow keys pressed in the panel move the selection in the pane.
extension MainWindowController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Call when the selection changes so an open panel follows it.
    func refreshQuickLook() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
              panel.isVisible, panel.dataSource === self else { return }
        panel.reloadData()
    }

    private var previewURLs: [URL] {
        paneGroup.activePane.selectedItems.map(\.url)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let urls = previewURLs
        return index < urls.count ? urls[index] as NSURL : nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, let table = paneGroup.activePane.browser.activeTableView else { return false }
        if event.keyCode == 49 { panel.orderOut(nil); return true } // Space closes, like Finder.
        table.keyDown(with: event)
        return true
    }
}
