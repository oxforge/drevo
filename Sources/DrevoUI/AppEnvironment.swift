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
    private let overridesURL: URL?
    private(set) var keyMap: KeyMap
    private(set) var keyMapProblems: [String] = []

    init(preferences: Preferences, opener: FileOpening? = nil, overridesURL: URL? = KeyMap.userOverridesURL,
         operations: OperationsCenter? = nil, shellSetup: ShellSetup? = nil) {
        self.preferences = preferences
        self.shellSetup = shellSetup ?? ShellSetup()
        self.opener = opener ?? WorkspaceOpener()
        self.operations = operations ?? OperationsCenter(prompts: SheetPrompts())
        self.overridesURL = overridesURL
        (keyMap, keyMapProblems) = KeyMap.load(preferences: preferences, overridesURL: overridesURL)
    }

    static func ephemeral(opener: FileOpening? = nil, operations: OperationsCenter? = nil, shellSetup: ShellSetup? = nil) -> AppEnvironment {
        AppEnvironment(preferences: .ephemeral(), opener: opener, overridesURL: nil, operations: operations, shellSetup: shellSetup)
    }

    func reloadKeyMap() {
        (keyMap, keyMapProblems) = KeyMap.load(preferences: preferences, overridesURL: overridesURL)
        NotificationCenter.default.post(name: Self.keyMapDidChange, object: self)
    }
}
