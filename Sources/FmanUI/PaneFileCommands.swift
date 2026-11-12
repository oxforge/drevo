import AppKit
import FmanCore

/// Remembers a ⌘X so the next paste moves instead of copies.
@MainActor
enum CutBuffer {
    static var changeCount: Int?
}

/// File operations on a pane's selection.
extension PaneViewController {
    var operations: OperationsCenter { env.operations }

    /// Commands that change files; false if `id` isn't one.
    func performFileCommand(_ id: CommandID) -> Bool {
        switch id {
        case .rename: renameSelection()
        case .newFolder: newItem(folder: true)
        case .newFile: newItem(folder: false)
        case .moveToTrash: trashSelection()
        case .deleteImmediately: deleteSelection()
        case .duplicate: duplicateSelection()
        case .makeAlias: aliasSelection()
        case .copyPath: copyPaths()
        case .pasteMove: pasteFiles(move: true)
        case .edit: editSelection()
        case .showPackageContents: showPackageContents()
        case .revealInFinder: revealInFinder()
        case .getInfo: showInfo()
        default: return false
        }
        return true
    }

    func canPerformFileCommand(_ id: CommandID) -> Bool {
        let hasSelection = !selectedItems.isEmpty
        switch id {
        case .rename: return selectedItems.count == 1
        case .moveToTrash, .deleteImmediately, .duplicate, .makeAlias: return hasSelection
        case .newFolder, .newFile, .copyPath, .edit, .revealInFinder, .getInfo: return true
        case .showPackageContents: return selectedItems.count == 1 && selectedItems[0].isPackage
        case .pasteMove: return Self.pasteboardFileURLs(env.pasteboard).isEmpty == false
        default: return false
        }
    }

    /// Re-reads the folder and selects `urls` (when given).
    func reload(selecting urls: [URL]) {
        reload()
        if !urls.isEmpty { browser.select(urls) }
    }

    /// Re-reads the folder and selects those of an operation's `results` that landed in
    /// it. The operation may have named this folder by another path (through a symlink,
    /// /tmp for /private/tmp, another letter case), so the folders are compared by
    /// identity and the results are looked up under this pane's own path.
    func reload(selectingResults results: [URL]) {
        let here = currentDirectory
        var isHere: [String: Bool] = [:]
        let landed = results.filter { url in
            let folder = url.deletingLastPathComponent()
            if let known = isHere[folder.path] { return known }
            let same = FileIdentity.sameItem(folder, here)
            isHere[folder.path] = same
            return same
        }
        reload(selecting: landed.map { here.appendingPathComponent($0.lastPathComponent) })
    }

    // MARK: Rename / create

    func renameSelection() {
        guard selectedItems.count == 1, let item = selectedItems.first else { return }
        beginRename(item.url)
    }

    func beginRename(_ url: URL) {
        browser.beginRename(url) { [weak self] newName in
            guard let self else { return }
            let pending = self.reloadPendingAfterRename
            self.reloadPendingAfterRename = false
            guard let newName else {
                if pending { self.reload() }
                return
            }
            let renamed: URL? = self.operations.perform("Rename", in: self.view.window) {
                try self.operations.ops.rename(url, to: newName)
            }
            if let renamed { self.reload(selecting: [renamed]) } else if pending { self.reload() }
            self.focus()
        }
    }

    func newItem(folder: Bool) {
        let dir = currentDirectory
        let made: URL? = operations.perform(folder ? "New Folder" : "New File", in: view.window) {
            folder ? try self.operations.ops.makeFolder(in: dir) : try self.operations.ops.makeFile(in: dir)
        }
        guard let made else { return }
        reload(selecting: [made])
        beginRename(made)
    }

    // MARK: Remove

    func trashSelection() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        let next = indexAfterRemoving(items)
        let done: Bool? = operations.perform("Move to Trash", in: view.window) {
            (true, try self.operations.ops.moveToTrash(items.map(\.url)))
        }
        if done == true { selectNearby(next) }
    }

    func deleteSelection() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        operations.prompts.confirmDelete(items.map(\.url), in: view.window) { [weak self] ok in
            guard let self, ok else { return }
            let next = self.indexAfterRemoving(items)
            let done: Bool? = self.operations.perform("Delete", in: self.view.window) {
                try self.operations.ops.deleteImmediately(items.map(\.url))
                return (true, nil)
            }
            if done == true { self.selectNearby(next) }
        }
    }

    private func indexAfterRemoving(_ items: [FileItem]) -> Int {
        let urls = Set(items.map(\.url))
        return browser.visibleItems.firstIndex { urls.contains($0.url) } ?? 0
    }

    private func selectNearby(_ index: Int) {
        let items = browser.visibleItems
        guard !items.isEmpty else { return }
        browser.select([items[min(index, items.count - 1)].url])
    }

    // MARK: Duplicate / alias

    func duplicateSelection() {
        let urls = selectedItems.map(\.url)
        if let made: [URL] = operations.perform("Duplicate", in: view.window, { try self.operations.ops.duplicate(urls) }) {
            reload(selecting: made)
        }
    }

    func aliasSelection() {
        let urls = selectedItems.map(\.url)
        if let made: [URL] = operations.perform("Make Alias", in: view.window, { try self.operations.ops.makeAlias(urls) }) {
            reload(selecting: made)
        }
    }

    // MARK: Clipboard

    func copyPaths() {
        let paths = selectedItems.isEmpty ? [currentDirectory.path] : selectedItems.map(\.url.path)
        let pb = env.pasteboard
        pb.clearContents()
        pb.setString(paths.joined(separator: "\n"), forType: .string)
    }

    static func pasteboardFileURLs(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func writeSelection(cut: Bool) {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        let pb = env.pasteboard
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        CutBuffer.changeCount = cut ? pb.changeCount : nil
    }

    func pasteFiles(move forceMove: Bool) {
        let pb = env.pasteboard
        let urls = Self.pasteboardFileURLs(pb)
        guard !urls.isEmpty else { NSSound.beep(); return }
        let wasCut = CutBuffer.changeCount == pb.changeCount
        let move = forceMove || wasCut
        if wasCut { CutBuffer.changeCount = nil }
        let dest = currentDirectory
        operations.transfer(move ? .move : .copy, urls, to: dest, window: view.window) { [weak self] result in
            self?.reload(selecting: result.outputs)
        }
    }

    @objc func copy(_ sender: Any?) { writeSelection(cut: false) }
    @objc func cut(_ sender: Any?) { writeSelection(cut: true) }
    @objc func paste(_ sender: Any?) { pasteFiles(move: false) }
}

extension PaneViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(cut(_:)): return !selectedItems.isEmpty
        case #selector(paste(_:)): return !Self.pasteboardFileURLs(env.pasteboard).isEmpty
        default: return true
        }
    }
}
