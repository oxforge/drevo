import AppKit
import DrevoCore

/// Source-list sidebar: Favorites and Locations (mounted volumes).
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    final class Section: NSObject {
        let title: String
        var items: [Entry]
        init(_ title: String, _ items: [Entry]) { self.title = title; self.items = items }
    }

    final class Entry: NSObject {
        let url: URL
        let title: String
        let symbol: String?
        let isVolume: Bool
        init(url: URL, title: String, symbol: String?, isVolume: Bool = false) {
            self.url = url; self.title = title; self.symbol = symbol; self.isVolume = isVolume
        }
    }

    let env: AppEnvironment
    var onNavigate: ((URL) -> Void)?
    private let outline = NSOutlineView()
    private(set) var sections: [Section] = []
    private var volumeObservers: [NSObjectProtocol] = []

    init(env: AppEnvironment) {
        self.env = env
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .default
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked(_:))
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        view = scroll
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        outline.sizeLastColumnToFit()
        reloadSections()

        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            volumeObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadSections() }
            })
        }
    }

    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        volumeObservers.forEach { nc.removeObserver($0) }
    }

    static func defaultFavorites() -> [URL] {
        let fm = FileManager.default
        var urls = [fm.homeDirectoryForCurrentUser]
        for d: FileManager.SearchPathDirectory in [.desktopDirectory, .documentDirectory, .downloadsDirectory] {
            if let u = fm.urls(for: d, in: .userDomainMask).first { urls.append(u) }
        }
        urls.append(URL(fileURLWithPath: "/Applications"))
        let iCloud = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: iCloud.path) { urls.append(iCloud) }
        return urls
    }

    private static func symbol(for url: URL) -> String {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        switch url.standardizedFileURL.path {
        case home: return "house"
        case home + "/Desktop": return "menubar.dock.rectangle"
        case home + "/Documents": return "doc"
        case home + "/Downloads": return "arrow.down.circle"
        case "/Applications": return "app.dashed"
        case home + "/Library/Mobile Documents/com~apple~CloudDocs": return "icloud"
        default: return "folder"
        }
    }

    func reloadSections() {
        let favoriteURLs = env.preferences.favoritePaths.map { $0.map { URL(fileURLWithPath: $0) } } ?? Self.defaultFavorites()
        let favorites = favoriteURLs.map { url -> Entry in
            let isICloud = url.path.hasSuffix("com~apple~CloudDocs")
            return Entry(url: url, title: isICloud ? "iCloud Drive" : Formatting.displayName(url), symbol: Self.symbol(for: url))
        }
        let volumeURLs = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeLocalizedNameKey], options: [.skipHiddenVolumes]) ?? []
        let volumes = volumeURLs.map { url -> Entry in
            let name = (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? url.lastPathComponent
            return Entry(url: url, title: name, symbol: nil, isVolume: true)
        }
        sections = [Section("Favorites", favorites), Section("Locations", volumes)]
        outline.reloadData()
        sections.forEach { outline.expandItem($0) }
    }

    /// Adds a folder to Favorites (Add to Sidebar, ⌃⌘T).
    func addFavorite(_ url: URL) {
        var paths = env.preferences.favoritePaths ?? Self.defaultFavorites().map(\.path)
        let key = DirectoryWatcher.normalize(url.path)
        guard !paths.contains(where: { DirectoryWatcher.normalize($0) == key }) else { return }
        paths.append(url.path)
        env.preferences.favoritePaths = paths
        reloadSections()
    }

    func removeFavorite(_ url: URL) {
        var paths = env.preferences.favoritePaths ?? Self.defaultFavorites().map(\.path)
        let key = DirectoryWatcher.normalize(url.path)
        paths.removeAll { DirectoryWatcher.normalize($0) == key }
        env.preferences.favoritePaths = paths
        reloadSections()
    }

    // MARK: Drops

    /// Drop onto an entry copies/moves into it; dropping folders between favorites adds them.
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let urls = FileDragDrop.fileURLs(info)
        guard !urls.isEmpty else { return [] }
        if let entry = item as? Entry, index == NSOutlineViewDropOnItemIndex {
            if urls.contains(where: { entry.url.isInside($0) }) { return [] }
            return FileDragDrop.kind(info, sources: urls, destination: entry.url) == .copy ? .copy : .move
        }
        if let section = item as? Section, section === sections.first, index != NSOutlineViewDropOnItemIndex,
           urls.allSatisfy(\.isDirectoryOnDisk) {
            return .link
        }
        return []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let urls = FileDragDrop.fileURLs(info)
        if let entry = item as? Entry {
            let kind = FileDragDrop.kind(info, sources: urls, destination: entry.url)
            env.operations.transfer(kind, urls, to: entry.url, window: view.window)
            return true
        }
        if item is Section {
            urls.forEach { addFavorite($0) }
            return true
        }
        return false
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let entry = outline.item(atRow: outline.clickedRow) as? Entry else { return }
        let reveal = menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealEntry(_:)), keyEquivalent: "")
        reveal.representedObject = entry
        reveal.target = self
        if entry.isVolume {
            if entry.url.path != "/" {
                let eject = menu.addItem(withTitle: "Eject “\(entry.title)”", action: #selector(ejectEntry(_:)), keyEquivalent: "")
                eject.representedObject = entry
                eject.target = self
            }
        } else {
            let remove = menu.addItem(withTitle: "Remove from Sidebar", action: #selector(removeEntry(_:)), keyEquivalent: "")
            remove.representedObject = entry
            remove.target = self
        }
    }

    @objc private func revealEntry(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? Entry else { return }
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    @objc private func removeEntry(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? Entry else { return }
        removeFavorite(entry.url)
    }

    @objc private func ejectEntry(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? Entry else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: entry.url)
        } catch {
            env.operations.prompts.showError("Couldn’t eject “\(entry.title)”.", detail: error.localizedDescription, in: view.window)
        }
    }

    @objc private func clicked(_ sender: Any?) {
        guard let entry = outline.item(atRow: outline.clickedRow) as? Entry else { return }
        onNavigate?(entry.url)
    }

    // MARK: Outline data

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return sections.count }
        return (item as? Section)?.items.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return sections[index] }
        return (item as! Section).items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is Section }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is Section }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is Entry }
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let section = item as? Section {
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: section.title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
        guard let entry = item as? Entry else { return nil }
        let id = NSUserInterfaceItemIdentifier("entry")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? SidebarCell ?? {
            let c = SidebarCell(); c.identifier = id; return c
        }()
        cell.configure(entry)
        return cell
    }

    final class SidebarCell: NSTableCellView {
        private let icon = NSImageView()
        private let label = NSTextField(labelWithString: "")

        init() {
            super.init(frame: .zero)
            imageView = icon
            textField = label
            label.lineBreakMode = .byTruncatingTail
            for v in [icon, label] {
                v.translatesAutoresizingMaskIntoConstraints = false
                addSubview(v)
            }
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18),
                icon.heightAnchor.constraint(equalToConstant: 18),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        func configure(_ entry: Entry) {
            label.stringValue = entry.title
            if let symbol = entry.symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: entry.title) {
                icon.image = image
                icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
                icon.contentTintColor = .controlAccentColor
            } else {
                let image = FileIcons.shared.icon(for: entry.url).copy() as! NSImage
                image.size = NSSize(width: 18, height: 18)
                icon.image = image
                icon.contentTintColor = nil
            }
        }
    }
}
