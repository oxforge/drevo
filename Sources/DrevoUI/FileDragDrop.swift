import AppKit
import DrevoCore

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

    /// The ⌥ (copy) and ⌘ (move) keys, as the drag's operation mask carries them.
    private static func modifierKeys(_ mask: NSDragOperation) -> (option: Bool, command: Bool) {
        (mask == .copy, mask == .generic || mask == .move)
    }

    /// Copy or move, from the modifier keys the drag carries.
    static func kind(_ info: NSDraggingInfo, sources: [URL], destination: URL) -> TransferKind {
        let keys = modifierKeys(info.draggingSourceOperationMask)
        return DropPolicy.kind(sources: sources, destination: destination, optionKey: keys.option, commandKey: keys.command)
    }

    /// The drag being validated. Validation runs on every mouse move; reading the
    /// pasteboard and looking up each item's real path and volume there made a big
    /// selection stutter, so that happens once per drag.
    private static var currentDrag: (sequenceNumber: Int, changeCount: Int, files: DraggedFiles)?

    /// The files `info` carries, worked out on the drag's first event and reused for the rest.
    static func draggedFiles(_ info: NSDraggingInfo) -> DraggedFiles {
        let sequenceNumber = info.draggingSequenceNumber
        let changeCount = info.draggingPasteboard.changeCount
        if let drag = currentDrag, drag.sequenceNumber == sequenceNumber, drag.changeCount == changeCount {
            return drag.files
        }
        let files = DraggedFiles(fileURLs(info))
        currentDrag = (sequenceNumber, changeCount, files)
        return files
    }

    /// Where a drop at `row` lands: onto a folder row, else the shown folder (retargets the table).
    static func validate(_ table: NSTableView, info: NSDraggingInfo, row: Int, operation: NSTableView.DropOperation,
                         items: [FileItem], directory: URL) -> NSDragOperation {
        let dragged = draggedFiles(info)
        guard !dragged.urls.isEmpty else { return [] }
        var dest = directory
        if operation == .on, row >= 0, row < items.count, items[row].isContainer {
            dest = items[row].url
        } else {
            table.setDropRow(-1, dropOperation: .on)
        }
        return dropOperation(info, onto: dest)
    }

    /// What dropping the drag's files into `dest` would do; `[]` when it makes no sense:
    /// a folder into itself, or a move of items onto the folder they're already in.
    static func dropOperation(_ info: NSDraggingInfo, onto dest: URL) -> NSDragOperation {
        let dragged = draggedFiles(info)
        guard !dragged.urls.isEmpty, !dragged.contain(dest) else { return [] }
        let keys = modifierKeys(info.draggingSourceOperationMask)
        let kind = dragged.kind(onto: dest, optionKey: keys.option, commandKey: keys.command)
        if kind == .move, dragged.areAll(in: dest) { return [] }
        return kind == .copy ? .copy : .move
    }

    static func destination(row: Int, operation: NSTableView.DropOperation, items: [FileItem], directory: URL) -> URL {
        if operation == .on, row >= 0, row < items.count, items[row].isContainer { return items[row].url }
        return directory
    }
}

/// What a drag carries, with everything validation asks about the items looked up once.
/// The questions give the answers of `URL.isInside`, `FileIdentity.sameItem` and
/// `DropPolicy.kind(sources:…)` asked item by item, at a cost per mouse move that
/// doesn't grow with the number of items.
@MainActor
final class DraggedFiles {
    let urls: [URL]
    /// The items as the volume knows them; an item that is a symlink is itself, not its
    /// target (as in `isInside`).
    private let itemIDs: Set<FileIdentity>
    /// Items that aren't on disk have no identity; `isInside` compares their paths.
    private let missingItems: [[String]]
    /// The folders the items are in, each one once.
    private let parents: [(path: String, id: FileIdentity?)]
    /// The volume all items are on; nil if they are on several or it isn't known.
    private let volume: AnyHashable?

    init(_ urls: [URL]) {
        self.urls = urls
        var ids = Set<FileIdentity>()
        var missing: [[String]] = []
        var parents: [(path: String, id: FileIdentity?)] = []
        var seenParents = Set<String>()
        for url in urls {
            let item = url.standardizedFileURL
            if let id = FileIdentity.of(item, followLinks: false) {
                ids.insert(id)
            } else {
                missing.append(item.pathComponents)
            }
            let parent = url.deletingLastPathComponent().standardizedFileURL
            if seenParents.insert(parent.path).inserted {
                parents.append((parent.path, FileIdentity.of(parent, followLinks: true)))
            }
        }
        itemIDs = ids
        missingItems = missing
        self.parents = parents
        let volumes = urls.map { DropPolicy.volumeIdentifier(of: $0) }
        volume = volumes.dropFirst().allSatisfy { $0 == volumes[0] } ? volumes.first ?? nil : nil
    }

    /// True if `folder` is one of the items or inside one.
    func contain(_ folder: URL) -> Bool {
        if !itemIDs.isEmpty, folder.isOrIsHeld(by: itemIDs.contains) { return true }
        guard !missingItems.isEmpty else { return false }
        let components = folder.standardizedFileURL.pathComponents
        return missingItems.contains { components.starts(with: $0) }
    }

    /// True if every item already is in `folder`, whichever path names it.
    func areAll(in folder: URL) -> Bool {
        let folder = folder.standardizedFileURL
        let folderID = FileIdentity.of(folder, followLinks: true)
        return !parents.isEmpty && parents.allSatisfy { parent in
            // As `FileIdentity.sameItem`: paths decide only when one side isn't on disk.
            if let id = parent.id, let folderID { return id == folderID }
            return parent.path == folder.path
        }
    }

    /// Finder's rule: a plain drag moves within a volume and copies to another one.
    func kind(onto folder: URL, optionKey: Bool, commandKey: Bool) -> TransferKind {
        DropPolicy.kind(sourceVolume: volume, destinationVolume: DropPolicy.volumeIdentifier(of: folder),
                        optionKey: optionKey, commandKey: commandKey)
    }
}
