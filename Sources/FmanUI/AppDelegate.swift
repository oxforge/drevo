import AppKit
import FmanCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: LaunchOptions
    private(set) var env: AppEnvironment!
    private(set) var windowControllers: [MainWindowController] = []
    private var observers: [NSObjectProtocol] = []

    init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch options.appearance {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        env = options.ephemeralSettings ? .ephemeral() : AppEnvironment(preferences: .shared)
        keyBindingsStamp = Self.modificationDate(KeyMap.userOverridesURL)
        NSApp.mainMenu = MainMenu.build(keyMap: env.keyMap)
        observers.append(NotificationCenter.default.addObserver(forName: AppEnvironment.keyMapDidChange, object: env, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSApp.mainMenu = MainMenu.build(keyMap: self.env.keyMap)
            }
        })

        let wc: MainWindowController
        if options.openPaths.isEmpty, env.preferences.restoreState,
           let saved = WindowState.decode(env.preferences.savedWindowState)?.validated() {
            wc = openWindow(directories: saved.directories, viewModes: saved.viewModes)
            wc.paneGroup.activate(index: saved.activeIndex)
        } else {
            wc = openWindow(directories: initialDirectories())
        }
        NSApp.activate()

        if let path = options.snapshotPath {
            if let command = options.snapshotCommand {
                wc.commandBar.field.stringValue = command
                wc.commandBar.submit(inTerminal: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (options.snapshotCommand == nil ? 0.8 : 2.5)) {
                do {
                    try Snapshot.write(window: wc.window!, overlays: [wc.sidebar.view], to: URL(fileURLWithPath: path))
                    exit(0)
                } catch {
                    FileHandle.standardError.write("snapshot failed: \(error)\n".data(using: .utf8)!)
                    exit(1)
                }
            }
        }
    }

    private func initialDirectories() -> [URL] {
        let count = env.preferences.paneCount
        var dirs = options.openPaths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        while dirs.count < max(count, options.openPaths.isEmpty ? count : dirs.count) { dirs.append(dirs.last ?? home) }
        return dirs
    }

    @discardableResult
    func openWindow(directories: [URL], viewModes: [ViewMode] = []) -> MainWindowController {
        let wc = MainWindowController(env: env, directories: directories, viewModes: viewModes, autosave: !options.ephemeralSettings)
        windowControllers.append(wc)
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: wc.window, queue: .main) { [weak self, weak wc] _ in
            MainActor.assumeIsolated { self?.windowControllers.removeAll { $0 === wc } }
        })
        wc.showWindow(nil)
        return wc
    }

    @objc func newWindow(_ sender: Any?) {
        if let group = windowControllers.last?.paneGroup {
            openWindow(directories: group.panes.map(\.currentDirectory), viewModes: group.panes.map(\.viewMode))
        } else {
            openWindow(directories: initialDirectories())
        }
    }

    /// Menu commands with no window open (only New Window works then).
    @objc func performCommand(_ sender: Any?) {
        if (sender as? NSMenuItem)?.representedObject as? String == CommandID.newWindow.rawValue {
            newWindow(sender)
        }
    }

    @objc func showSettings(_ sender: Any?) {}

    @objc func showShortcuts(_ sender: Any?) {
        ShortcutsWindow.show(keyMap: env.keyMap)
    }

    /// Writes keybindings.json (if missing) and the defaults reference, then opens it.
    @objc func editKeyBindings(_ sender: Any?) {
        let url = KeyMap.userOverridesURL
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try KeyMap().templateJSON().write(to: dir.appendingPathComponent("keybindings.defaults.json"), atomically: true, encoding: .utf8)
            if !FileManager.default.fileExists(atPath: url.path) {
                try KeyMap.starterJSON.write(to: url, atomically: true, encoding: .utf8)
            }
            let editor = env.preferences.editorAppPath.map { URL(fileURLWithPath: $0) }
                ?? NSWorkspace.shared.urlForApplication(toOpen: .plainText)
                ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
            env.opener.open([url], withApplicationAt: editor)
            keyBindingsStamp = Self.modificationDate(url)
        } catch {
            env.operations.prompts.showError("Couldn’t create keybindings.json.", detail: error.localizedDescription, in: NSApp.keyWindow)
        }
    }

    private var keyBindingsStamp: Date?

    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Picks up keybindings.json edits when the user comes back to fman.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !options.ephemeralSettings else { return }
        let stamp = Self.modificationDate(KeyMap.userOverridesURL)
        guard stamp != keyBindingsStamp else { return }
        keyBindingsStamp = stamp
        env.reloadKeyMap()
        var problems = env.keyMapProblems
        let conflicts = env.keyMap.conflicts.map { "\($0.key) is bound to \($0.value.map(\.rawValue).joined(separator: " and "))" }
        problems += conflicts
        if !problems.isEmpty {
            env.operations.prompts.showError("Some key bindings weren’t applied.", detail: problems.joined(separator: "\n"), in: NSApp.keyWindow)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }
}
