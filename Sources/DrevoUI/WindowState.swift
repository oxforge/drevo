import DrevoCore
import Foundation

/// What a window looked like, saved so the next launch opens the same panes.
struct WindowState: Codable, Equatable {
    struct Pane: Codable, Equatable {
        var path: String
        var viewMode: String
        /// Absent in state saved by older builds.
        var sortKey: String?
        var ascending: Bool?
        /// The pane's tabs when it has more than one (the fields above are the active
        /// tab's); absent otherwise and in state saved by older builds.
        var tabs: [Pane]?
        var activeTab: Int?

        var sort: FileSort {
            guard let key = sortKey.flatMap(SortKey.init(rawValue:)) else { return FileSort() }
            return FileSort(key: key, ascending: ascending ?? key.defaultAscending)
        }
    }

    var panes: [Pane]
    var activeIndex: Int

    var directories: [URL] { panes.map { URL(fileURLWithPath: $0.path) } }
    var viewModes: [ViewMode] { panes.map { ViewMode(rawValue: $0.viewMode) ?? .columns } }
    var sorts: [FileSort] { panes.map(\.sort) }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    static func decode(_ data: Data?) -> WindowState? {
        guard let data, let s = try? JSONDecoder().decode(WindowState.self, from: data), !s.panes.isEmpty else { return nil }
        return s
    }

    /// Drops panes whose folder is gone (unmounted drive, deleted folder) by falling back to Home.
    func validated(fileManager: FileManager = .default) -> WindowState {
        var copy = self
        let home = fileManager.homeDirectoryForCurrentUser.path
        func existingFolder(_ path: String) -> String {
            var isDir: ObjCBool = false
            return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue ? path : home
        }
        for i in copy.panes.indices {
            copy.panes[i].path = existingFolder(copy.panes[i].path)
            for t in (copy.panes[i].tabs ?? []).indices {
                copy.panes[i].tabs![t].path = existingFolder(copy.panes[i].tabs![t].path)
            }
        }
        copy.panes = Array(copy.panes.prefix(4))
        copy.activeIndex = min(max(0, activeIndex), copy.panes.count - 1)
        return copy
    }
}

extension WindowState.Pane {
    init(_ tab: PaneTab) {
        self.init(path: tab.directory.path, viewMode: tab.viewMode.rawValue, sortKey: tab.sort.key.rawValue, ascending: tab.sort.ascending)
    }

    var tab: PaneTab {
        PaneTab(history: NavigationHistory(start: URL(fileURLWithPath: path)), viewMode: ViewMode(rawValue: viewMode) ?? .columns, sort: sort)
    }
}

extension PaneGroupViewController {
    var state: WindowState {
        WindowState(panes: panes.map { pane in
            var saved = WindowState.Pane(path: pane.currentDirectory.path, viewMode: pane.viewMode.rawValue,
                                         sortKey: pane.sort.key.rawValue, ascending: pane.sort.ascending)
            if pane.tabCount > 1 {
                saved.tabs = pane.tabs.map(WindowState.Pane.init)
                saved.activeTab = pane.activeTabIndex
            }
            return saved
        }, activeIndex: activeIndex)
    }

    /// Reopens the tabs of panes that had several.
    func restoreTabs(from state: WindowState) {
        for (pane, saved) in zip(panes, state.panes) {
            guard let tabs = saved.tabs, tabs.count > 1 else { continue }
            pane.restoreTabs(tabs.map(\.tab), active: saved.activeTab ?? 0)
        }
    }
}
