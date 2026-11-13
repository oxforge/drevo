import AppKit
import DrevoCore

/// Opens files and apps. Tests swap in a recorder so nothing launches.
@MainActor
protocol FileOpening: AnyObject {
    func open(_ urls: [URL])
    func open(_ urls: [URL], withApplicationAt app: URL)
}

@MainActor
final class WorkspaceOpener: FileOpening {
    func open(_ urls: [URL]) {
        for url in urls { NSWorkspace.shared.open(url) }
    }

    func open(_ urls: [URL], withApplicationAt app: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Shared services for one app instance (tests build their own).
@MainActor
final class AppEnvironment {
    static let keyMapDidChange = Notification.Name("drevo.keyMapDidChange")

    let preferences: Preferences
    let opener: FileOpening
    let operations: OperationsCenter
    /// The general pasteboard; tests use a private one.
    var pasteboard: NSPasteboard = .general
    /// The user's shell setup, loaded once for the command line.
    let shellSetup: ShellSetup
    /// Spotlight for searches; tests search without it.
    var spotlight: FileSearch.SpotlightSource? = Spotlight.find
    /// Tests search inline so results are there right after the call.
    var runSearchesSynchronously = false
    /// keybindings.json; nil keeps the shortcut editor's changes in memory (tests,
    /// --ephemeral-settings).
    private let overridesURL: URL?
    private var memoryOverrides = KeyBindingsFile()
    /// The file's modification date at the last reload, to tell outside edits from ours.
    private var overridesStamp: Date?
    private var observers: [NSObjectProtocol] = []
    private(set) var keyMap: KeyMap
    private(set) var keyMapProblems: [String] = []
    /// Why keybindings.json can't be read, if it can't; the editor then leaves it alone.
    private(set) var keyBindingsFileError: String?

    init(preferences: Preferences, opener: FileOpening? = nil, overridesURL: URL? = KeyMap.userOverridesURL,
         operations: OperationsCenter? = nil, shellSetup: ShellSetup? = nil) {
        self.preferences = preferences
        self.shellSetup = shellSetup ?? ShellSetup()
        self.opener = opener ?? WorkspaceOpener()
        self.operations = operations ?? OperationsCenter(prompts: SheetPrompts())
        self.overridesURL = overridesURL
        keyMap = KeyMap()
        loadKeyMap()
        noteKeyBindingsFileWritten()
        observers.append(NotificationCenter.default.addObserver(forName: Preferences.didChange, object: preferences, queue: nil) { [weak self] note in
            guard note.userInfo?[Preferences.changedKey] as? Preferences.Key == .returnRenames else { return }
            MainActor.assumeIsolated { self?.returnSettingChanged() }
        })
    }

    static func ephemeral(opener: FileOpening? = nil, operations: OperationsCenter? = nil, shellSetup: ShellSetup? = nil) -> AppEnvironment {
        AppEnvironment(preferences: .ephemeral(), opener: opener, overridesURL: nil, operations: operations, shellSetup: shellSetup)
    }

    /// The registry defaults adjusted for the Return-key setting.
    var defaultKeyMap: KeyMap { KeyMap.defaults(returnRenames: preferences.returnRenames) }

    func reloadKeyMap() {
        loadKeyMap()
        overridesStamp = overridesURL.flatMap(Self.modificationDate)
        NotificationCenter.default.post(name: Self.keyMapDidChange, object: self)
    }

    /// Reloads when keybindings.json changed outside Drevo since the last reload; returns
    /// what's wrong with it then (unknown commands, unreadable keys, clashes), else nil.
    func reloadKeyMapIfFileChanged() -> [String]? {
        guard let url = overridesURL, Self.modificationDate(url) != overridesStamp else { return nil }
        reloadKeyMap()
        return keyMapProblems + keyMap.conflicts.map { "\($0.key) is bound to \($0.value.map(\.rawValue).joined(separator: " and "))" }
    }

    /// Notes keybindings.json as it is now as seen: loaded at launch, or written by Drevo
    /// itself (Help ▸ Edit keybindings.json).
    func noteKeyBindingsFileWritten() {
        overridesStamp = overridesURL.flatMap(Self.modificationDate)
    }

    // MARK: Shortcut editor

    /// Saves new keys for the commands in `changes`; a command whose keys are its default
    /// loses its entry. Throws when keybindings.json can't be read or written.
    func saveKeyChanges(_ changes: [CommandID: [KeyCombo]]) throws {
        let defaults = defaultKeyMap
        try updateOverrides { $0.apply(changes, defaults: defaults) }
    }

    func resetKeys(for id: CommandID) throws {
        try updateOverrides { $0.remove(id) }
    }

    /// Removes every command's entry, keeping comments; replaces a file that can't be read.
    func resetAllKeys() throws {
        try updateOverrides(replacingUnreadable: true) { $0.removeAllCommands() }
    }

    /// Reads the file fresh, changes it, writes it if that changed anything, and reloads.
    private func updateOverrides(replacingUnreadable: Bool = false, _ change: (inout KeyBindingsFile) -> Void) throws {
        guard let url = overridesURL else {
            change(&memoryOverrides)
            return reloadKeyMap()
        }
        var file = KeyBindingsFile()
        var unreadable = false
        if let data = try? Data(contentsOf: url) {
            do { file = try KeyBindingsFile(data: data) } catch {
                guard replacingUnreadable else { throw error }
                unreadable = true
            }
        }
        let before = file
        change(&file)
        if file != before || unreadable {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: url, options: .atomic)
        }
        reloadKeyMap()
    }

    /// Return follows the setting even when Open or Rename was edited. The key map still
    /// holds the keys from before the change.
    private func returnSettingChanged() {
        let changes = KeyRecording.movingReturn(to: preferences.returnRenames ? .rename : .open, in: keyMap)
        if (try? saveKeyChanges(changes)) == nil { reloadKeyMap() }
    }

    private func loadKeyMap() {
        let data = overridesURL.map { try? Data(contentsOf: $0) } ?? memoryOverrides.data
        (keyMap, keyMapProblems) = KeyMap.load(returnRenames: preferences.returnRenames, overrides: data)
        keyBindingsFileError = nil
        if let data {
            do { _ = try KeyBindingsFile(data: data) } catch { keyBindingsFileError = error.localizedDescription }
        }
    }

    /// Read from the file system each time (URL resource values are cached).
    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
