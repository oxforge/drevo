import AppKit
import FmanCore

/// Drag & drop for file tables: drag items out as file URLs, accept file URLs onto a
/// folder row or the folder's background. Finder semantics: same volume moves, another
/// volume copies, ⌥ copies, ⌘ moves.
@MainActor
enum FileDragDrop {
    static let acceptedTypes: [NSPasteboard.PasteboardType] = [.fileURL]

    /// Makes `table` a drag source and drop target.
    static func configure(_ table: NSTableView) {
        table.registerForDraggedTypes(acceptedTypes)
        table.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: true)
        table.setDraggingSourceOperationMask([.copy, .move, .link, .generic, .delete], forLocal: false)
        table.draggingDestinationFeedbackStyle = .regular
        table.verticalMotionCanBeginDrag = true
    }

    static func writer(for item: FileItem) -> NSPasteboardWriting {
        item.url as NSURL
    }

    static func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// Copy or move, from the modifier keys the drag carries.
    static func kind(_ info: NSDraggingInfo, sources: [URL], destination: URL) -> TransferKind {
        let mask = info.draggingSourceOperationMask
        let option = mask == .copy
        let command = mask == .generic || mask == .move
        return DropPolicy.kind(sources: sources, destination: destination, optionKey: option, commandKey: command)
    }

    /// Where a drop at `row` lands: onto a folder row, else the shown folder (retargets the table).
    static func validate(_ table: NSTableView, info: NSDraggingInfo, row: Int, operation: NSTableView.DropOperation,
                         items: [FileItem], directory: URL) -> NSDragOperation {
        let sources = fileURLs(info)
        guard !sources.isEmpty else { return [] }
        var dest = directory
        if operation == .on, row >= 0, row < items.count, items[row].isContainer {
            dest = items[row].url
        } else {
            table.setDropRow(-1, dropOperation: .on)
        }
        // Refuse dropping a folder into itself, or items onto the folder they're already in.
        if sources.contains(where: { dest.isInside($0) }) { return [] }
        if sources.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == dest.standardizedFileURL.path }),
           kind(info, sources: sources, destination: dest) == .move {
            return []
        }
        return kind(info, sources: sources, destination: dest) == .copy ? .copy : .move
    }

    static func destination(row: Int, operation: NSTableView.DropOperation, items: [FileItem], directory: URL) -> URL {
        if operation == .on, row >= 0, row < items.count, items[row].isContainer { return items[row].url }
        return directory
    }
}
