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
        for i in copy.panes.indices {
            var isDir: ObjCBool = false
            if !fileManager.fileExists(atPath: copy.panes[i].path, isDirectory: &isDir) || !isDir.boolValue {
                copy.panes[i].path = home
            }
        }
        copy.panes = Array(copy.panes.prefix(4))
        copy.activeIndex = min(max(0, activeIndex), copy.panes.count - 1)
        return copy
    }
}

extension PaneGroupViewController {
    var state: WindowState {
        WindowState(panes: panes.map { .init(path: $0.currentDirectory.path, viewMode: $0.viewMode.rawValue,
                                             sortKey: $0.sort.key.rawValue, ascending: $0.sort.ascending) },
                    activeIndex: activeIndex)
    }
}
