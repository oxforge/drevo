import AppKit
import DrevoCore

/// Where settings live: UserDefaults normally, memory for snapshots and tests.
protocol SettingsStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: SettingsStore {}

final class MemorySettingsStore: SettingsStore {
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

enum ViewMode: String, CaseIterable {
    case list, columns
}

enum RowSize: Int, CaseIterable {
    case small = 0, medium = 1, large = 2

    var rowHeight: CGFloat { [20, 24, 30][rawValue] }
    var fontSize: CGFloat { [12, 13, 14][rawValue] }
    var iconSize: CGFloat { [16, 16, 20][rawValue] }
    var title: String { ["Small", "Medium", "Large"][rawValue] }
}

/// App settings. Changing a value posts `Preferences.didChange` with its `Key` in
/// userInfo, except for the two that are saved state rather than settings (`windowState`,
/// `commandHistory`).
@MainActor
final class Preferences {
    /// The names the values are stored under.
    enum Key: String {
        case showHidden, foldersFirst, returnRenames, confirmTransfers, showKeyHints, showStatusBar
        case showCommandLine, showSidebar, showAllExtensions, relativeDates, restoreState, interactiveShell
        case rowSize, defaultViewMode, paneCount, terminalAppPath, editorAppPath
        case windowState, commandHistory, favorites
    }

    nonisolated static let didChange = Notification.Name("drevo.preferencesDidChange")
    /// userInfo key of the `Key` that changed; read in notification callbacks.
    nonisolated static let changedKey = "key"

    private let store: SettingsStore

    init(store: SettingsStore) {
        self.store = store
    }

    static let shared = Preferences(store: UserDefaults.standard)
    static func ephemeral() -> Preferences { Preferences(store: MemorySettingsStore()) }

    // MARK: Values

    var showHidden: Bool { get { bool(.showHidden, false) } set { set(newValue, .showHidden) } }
    var foldersFirst: Bool { get { bool(.foldersFirst, true) } set { set(newValue, .foldersFirst) } }
    var returnRenames: Bool { get { bool(.returnRenames, false) } set { set(newValue, .returnRenames) } }
    var confirmTransfers: Bool { get { bool(.confirmTransfers, true) } set { set(newValue, .confirmTransfers) } }
    var showKeyHints: Bool { get { bool(.showKeyHints, true) } set { set(newValue, .showKeyHints) } }
    var showStatusBar: Bool { get { bool(.showStatusBar, true) } set { set(newValue, .showStatusBar) } }
    var showCommandLine: Bool { get { bool(.showCommandLine, true) } set { set(newValue, .showCommandLine) } }
    var showSidebar: Bool { get { bool(.showSidebar, true) } set { set(newValue, .showSidebar) } }
    var showAllExtensions: Bool { get { bool(.showAllExtensions, true) } set { set(newValue, .showAllExtensions) } }
    var relativeDates: Bool { get { bool(.relativeDates, true) } set { set(newValue, .relativeDates) } }
    var restoreState: Bool { get { bool(.restoreState, true) } set { set(newValue, .restoreState) } }
    var interactiveShell: Bool { get { bool(.interactiveShell, true) } set { set(newValue, .interactiveShell) } }

    var rowSize: RowSize {
        get { RowSize(rawValue: (value(.rowSize) as? Int) ?? 1) ?? .medium }
        set { set(newValue.rawValue, .rowSize) }
    }

    var defaultViewMode: ViewMode {
        get { ViewMode(rawValue: (value(.defaultViewMode) as? String) ?? "") ?? .columns }
        set { set(newValue.rawValue, .defaultViewMode) }
    }

    var paneCount: Int {
        get { min(4, max(1, (value(.paneCount) as? Int) ?? 2)) }
        set { set(min(4, max(1, newValue)), .paneCount) }
    }

    /// Path of the terminal app for "Open in Terminal"; nil = Terminal.app.
    var terminalAppPath: String? {
        get { value(.terminalAppPath) as? String }
        set { set(newValue, .terminalAppPath) }
    }

    /// Path of the editor app for F4; nil = the default app for plain text.
    var editorAppPath: String? {
        get { value(.editorAppPath) as? String }
        set { set(newValue, .editorAppPath) }
    }

    /// Opaque saved window/pane state (see `WindowState`). Saved without a notification.
    var savedWindowState: Data? {
        get { value(.windowState) as? Data }
        set { store.set(newValue, forKey: Key.windowState.rawValue) }
    }

    /// Saved without a notification.
    var commandHistory: [String] {
        get { value(.commandHistory) as? [String] ?? [] }
        set { store.set(Array(newValue.suffix(200)), forKey: Key.commandHistory.rawValue) }
    }

    var favoritePaths: [String]? {
        get { value(.favorites) as? [String] }
        set { set(newValue, .favorites) }
    }

    // MARK: Derived

    func listingOptions(sort: FileSort, filter: String = "") -> ListingOptions {
        var s = sort
        s.foldersFirst = foldersFirst
        return ListingOptions(showHidden: showHidden, sort: s, filter: filter)
    }

    // MARK: Storage helpers

    private func value(_ key: Key) -> Any? {
        store.object(forKey: key.rawValue)
    }

    private func bool(_ key: Key, _ fallback: Bool) -> Bool {
        (value(key) as? Bool) ?? fallback
    }

    private func set(_ value: Any?, _ key: Key) {
        store.set(value, forKey: key.rawValue)
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: [Self.changedKey: key])
    }
}
